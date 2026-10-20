import Foundation
import os

/// Plain JSON files in Application Support. One file for cities, one per walk.
nonisolated struct Store {
    private static let log = Logger(subsystem: "com.mikecann.walkies", category: "store")

    private let root: URL
    private var citiesURL: URL { root.appending(path: "cities.json") }
    private var walksDir: URL { root.appending(path: "walks", directoryHint: .isDirectory) }

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Walkies", directoryHint: .isDirectory)) {
        self.root = root
        let isNew = !FileManager.default.fileExists(atPath: root.path)
        try? FileManager.default.createDirectory(at: walksDir, withIntermediateDirectories: true)
        if isNew { write(HexGrid.version, to: versionURL) }
    }

    private var versionURL: URL { root.appending(path: "data-version.json") }
    private var resetURL: URL { root.appending(path: "world-grid-reset.json") }

    /// Only geometry and identity survive. No legacy hex can leak into a rebuilt city.
    struct ResetPlace: Codable, Sendable {
        var id: UUID
        var name: String
        var detail: String
        var boundary: Boundary
        var osmId: Int?
        var createdAt: Date
    }

    var needsWorldGridReset: Bool {
        read(Int.self, from: versionURL) != HexGrid.version || FileManager.default.fileExists(atPath: resetURL.path)
    }

    func pendingResetPlaces() throws -> [ResetPlace] {
        try JSONDecoder().decode([ResetPlace].self, from: Data(contentsOf: resetURL))
    }

    /// The pending descriptor file is written first and removed last. Offline launches
    /// and a process killed halfway through replay can retry without losing the places.
    func prepareWorldGridReset() throws {
        guard read(Int.self, from: versionURL) != HexGrid.version else { return }
        if !FileManager.default.fileExists(atPath: resetURL.path) {
            let nearby = loadNearby()?.places ?? []
            let oldCities = FileManager.default.fileExists(atPath: citiesURL.path)
                ? try JSONDecoder().decode([City].self, from: Data(contentsOf: citiesURL)) : []
            let places = oldCities.map { city in
                ResetPlace(id: city.id, name: city.name, detail: city.detail, boundary: city.boundary,
                           osmId: city.osmId ?? nearby.first { $0.name == city.name && $0.detail == city.detail }?.osmId,
                           createdAt: city.createdAt)
            }
            try JSONEncoder().encode(places).write(to: resetURL, options: .atomic)
        }
        for url in [citiesURL, stickersURL, progressURL, nearbyURL, syncURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        for var walk in loadWalks() {
            walk.resetGridCoverage()
            try JSONEncoder().encode(walk).write(to: file(for: walk), options: .atomic)
        }
        try JSONEncoder().encode(HexGrid.version).write(to: versionURL, options: .atomic)
    }

    func finishWorldGridReset(cities: [City], walks: [Walk], stickers: [String: Date], progress: Ledger) throws {
        // Failures must leave the retry marker intact, unlike ordinary best-effort saves.
        for walk in walks { try JSONEncoder().encode(walk).write(to: file(for: walk), options: .atomic) }
        try JSONEncoder().encode(cities).write(to: citiesURL, options: .atomic)
        try JSONEncoder().encode(stickers).write(to: stickersURL, options: .atomic)
        try JSONEncoder().encode(progress).write(to: progressURL, options: .atomic)
        if FileManager.default.fileExists(atPath: resetURL.path) { try FileManager.default.removeItem(at: resetURL) }
    }

    func loadCities() -> [City] {
        read([City].self, from: citiesURL) ?? []
    }

    func save(_ cities: [City]) {
        write(cities, to: citiesURL)
    }

    private var teamsURL: URL { root.appending(path: "teams.json") }
    func loadTeams() -> [Team] {
        read([Team].self, from: teamsURL) ?? []
    }

    func save(teams: [Team]) {
        write(teams, to: teamsURL)
    }

    /// When each sticker was found, by lore id.
    func loadStickers() -> [String: Date] {
        read([String: Date].self, from: stickersURL) ?? [:]
    }

    func save(stickers: [String: Date]) {
        write(stickers, to: stickersURL)
    }

    private var stickersURL: URL { root.appending(path: "stickers.json") }

    func loadSyncState() -> SyncState {
        read(SyncState.self, from: syncURL) ?? SyncState()
    }

    func save(syncState: SyncState) {
        write(syncState, to: syncURL)
    }

    func loadProgress() -> Ledger {
        read(Ledger.self, from: progressURL) ?? Ledger()
    }

    func save(progress: Ledger) {
        write(progress, to: progressURL)
    }

    private var progressURL: URL { root.appending(path: "progress.json") }

    private var syncURL: URL { root.appending(path: "sync.json") }

    /// Suburbs around your places, so the map can offer them without asking OpenStreetMap every launch.
    func loadNearby() -> NearbyPlaces? {
        read(NearbyPlaces.self, from: nearbyURL)
    }

    func save(nearby: NearbyPlaces) {
        write(nearby, to: nearbyURL)
    }

    private var nearbyURL: URL { root.appending(path: "nearby.json") }

    /// Deletes everything the app has saved, for signing out.
    func wipe() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: walksDir, withIntermediateDirectories: true)
        write(HexGrid.version, to: versionURL)
    }

    func loadWalks() -> [Walk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: walksDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read(Walk.self, from: $0) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func save(_ walk: Walk) {
        write(walk, to: file(for: walk))
    }

    func delete(_ walk: Walk) {
        try? FileManager.default.removeItem(at: file(for: walk))
    }

    private func file(for walk: Walk) -> URL {
        walksDir.appending(path: "\(walk.id.uuidString).json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("Couldn't read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            Self.log.error("Couldn't save \(url.lastPathComponent): \(error)")
        }
    }
}

/// Suburbs found around your places, and the box they were looked for in.
nonisolated struct NearbyPlaces: Codable, Sendable {
    var south: Double
    var west: Double
    var north: Double
    var east: Double
    var fetchedAt: Date
    var places: [PlaceResult]

    func covers(south: Double, west: Double, north: Double, east: Double) -> Bool {
        self.south <= south && self.west <= west && self.north >= north && self.east >= east
    }
}
