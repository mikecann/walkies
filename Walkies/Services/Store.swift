import Foundation
import os

/// Plain JSON files in Application Support. One file for cities, one for their
/// streets, one per walk.
nonisolated struct Store {
    fileprivate static let log = Logger(subsystem: "com.mikecann.walkies", category: "store")

    private let root: URL
    private let cityFiles: CityFiles
    private var citiesURL: URL { root.appending(path: "cities.json") }
    private var roadsURL: URL { root.appending(path: "roads.json") }
    private var walksDir: URL { root.appending(path: "walks", directoryHint: .isDirectory) }

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Walkies", directoryHint: .isDirectory)) {
        self.root = root
        cityFiles = CityFiles.at(cities: root.appending(path: "cities.json"), roads: root.appending(path: "roads.json"))
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

    /// Keeps OSM ids found so far, so a retry doesn't search for them again.
    func savePendingResetPlaces(_ places: [ResetPlace]) throws {
        try JSONEncoder().encode(places).write(to: resetURL, options: .atomic)
    }

    /// The pending descriptor file is written first and removed last. Offline launches
    /// and a process killed halfway through replay can retry without losing the places.
    func prepareWorldGridReset() throws {
        guard read(Int.self, from: versionURL) != HexGrid.version else { return }
        cityFiles.flush()
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
        try cityFiles.replace {
            for url in [citiesURL, roadsURL, stickersURL, progressURL, nearbyURL, syncURL] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
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
        try cityFiles.write(cities)
        try JSONEncoder().encode(stickers).write(to: stickersURL, options: .atomic)
        try JSONEncoder().encode(progress).write(to: progressURL, options: .atomic)
        if FileManager.default.fileExists(atPath: resetURL.path) { try FileManager.default.removeItem(at: resetURL) }
    }

    /// A file that won't read is moved aside rather than saved over, and sync brings
    /// the places back from the account.
    func loadCities() -> [City] {
        cityFiles.flush()
        guard let data = try? Data(contentsOf: citiesURL) else { return [] }
        do {
            var cities = try JSONDecoder().decode([City].self, from: data)
            // Older saves kept the streets in cities.json. Missing ones are fetched again.
            let roads = read([String: [RoadLine]].self, from: roadsURL) ?? [:]
            var fromFile: [UUID: [RoadLine]] = [:]
            for i in cities.indices where cities[i].roads == nil {
                cities[i].roads = roads[cities[i].id.uuidString]
                fromFile[cities[i].id] = cities[i].roads
            }
            cityFiles.loaded(roads: fromFile)
            return cities
        } catch {
            let aside = root.appending(path: "cities.corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            Self.log.error("Couldn't read cities.json, moving it to \(aside.lastPathComponent): \(error)")
            try? FileManager.default.moveItem(at: citiesURL, to: aside)
            return []
        }
    }

    /// Written in the background, newest last. Reading the cities waits for it.
    func save(_ cities: [City]) {
        cityFiles.save(cities)
    }

    /// Waits for any cities still being written, say before the app is suspended.
    func flush() {
        cityFiles.flush()
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

    /// The user id of the account this phone's data belongs to.
    func loadOwner() -> String? {
        read(String.self, from: ownerURL)
    }

    func save(owner: String) {
        write(owner, to: ownerURL)
    }

    private var ownerURL: URL { root.appending(path: "owner.json") }

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
        cityFiles.replace {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: walksDir, withIntermediateDirectories: true)
        }
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

/// Writes the cities off the main thread, one save at a time, so saving during a walk
/// doesn't stall the map. Only the latest of several waiting saves is written. Each
/// city is only encoded again once it's changed, and the streets, which never change
/// once a place is built, live in their own file that's only written when they do.
private nonisolated final class CityFiles: @unchecked Sendable {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var all: [String: CityFiles] = [:]

    /// One per folder, so every Store on the same files writes in turn.
    static func at(cities: URL, roads: URL) -> CityFiles {
        registry.lock()
        defer { registry.unlock() }
        if let files = all[cities.path] { return files }
        let files = CityFiles(cities: cities, roads: roads)
        all[cities.path] = files
        return files
    }

    private let citiesURL: URL
    private let roadsURL: URL
    private let queue = DispatchQueue(label: "com.mikecann.walkies.cities", qos: .utility)
    private let lock = NSLock()
    private var waiting: [City]?
    // Only used on the queue.
    private var encoded: [UUID: (city: City, data: Data)] = [:]
    private var savedRoads: [UUID: [RoadLine]]?

    private init(cities: URL, roads: URL) {
        citiesURL = cities
        roadsURL = roads
    }

    func save(_ cities: [City]) {
        lock.lock()
        let queued = waiting != nil
        waiting = cities
        lock.unlock()
        if !queued { queue.async { self.writeWaiting() } }
    }

    func flush() {
        queue.sync { writeWaiting() }
    }

    /// Writes now, throwing if it can't.
    func write(_ cities: [City]) throws {
        try queue.sync {
            lock.lock()
            waiting = nil
            lock.unlock()
            try writeFiles(cities)
        }
    }

    /// For changing the files some other way: after anything waiting is written,
    /// and forgetting what's on disk.
    func replace(_ change: () throws -> Void) rethrows {
        try queue.sync {
            writeWaiting()
            encoded = [:]
            savedRoads = nil
            try change()
        }
    }

    /// The streets just read from roads.json, so the next save needn't write them again.
    func loaded(roads: [UUID: [RoadLine]]) {
        queue.sync { savedRoads = roads }
    }

    private func writeWaiting() {
        lock.lock()
        let cities = waiting
        waiting = nil
        lock.unlock()
        guard let cities else { return }
        do {
            try writeFiles(cities)
        } catch {
            Store.log.error("Couldn't save cities.json: \(error)")
        }
    }

    private static func roads(of cities: [City]) -> [UUID: [RoadLine]] {
        Dictionary(cities.compactMap { city in city.roads.map { (city.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// On the queue. Streets first, so cities.json never points at streets that aren't saved.
    private func writeFiles(_ cities: [City]) throws {
        let roads = Self.roads(of: cities)
        var inline = false
        if roads != savedRoads {
            do {
                let byID = Dictionary(uniqueKeysWithValues: roads.map { ($0.key.uuidString, $0.value) })
                try JSONEncoder().encode(byID).write(to: roadsURL, options: .atomic)
                savedRoads = roads
            } catch {
                Store.log.error("Couldn't save roads.json, keeping the streets in cities.json: \(error)")
                savedRoads = nil
                inline = true
            }
        }
        var next: [UUID: (city: City, data: Data)] = [:]
        var parts: [Data] = []
        for city in cities {
            var bare = city
            if !inline { bare.roads = nil }
            let data: Data
            if let old = encoded[city.id], old.city == bare {
                data = old.data
            } else {
                data = try JSONEncoder().encode(bare)
            }
            next[city.id] = (bare, data)
            parts.append(data)
        }
        // The same JSON as encoding the whole array.
        var file = Data("[".utf8)
        for (i, part) in parts.enumerated() {
            if i > 0 { file.append(UInt8(ascii: ",")) }
            file.append(part)
        }
        file.append(UInt8(ascii: "]"))
        try file.write(to: citiesURL, options: .atomic)
        encoded = next
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
