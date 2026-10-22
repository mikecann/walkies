import Foundation
import Testing
@testable import Walkies

/// The same values, written by literals only, as `Fixtures` in the Android tests
/// (android/app/src/test/.../FixtureTest.kt). Change both together.
enum FixtureValues {
    static let placeA = UUID(uuidString: "0E5F6C1A-2B3C-4D5E-8F90-A1B2C3D4E5F6")!
    static let placeB = UUID(uuidString: "6A1B2C3D-4E5F-4061-8728-394A5B6C7D8E")!
    static let placeC = UUID(uuidString: "F0E1D2C3-B4A5-4697-8879-6A5B4C3D2E1F")!
    static let credit = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    static let walk1 = UUID(uuidString: "A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5")!
    static let walk2 = UUID(uuidString: "B2B2B2B2-C3C3-4D4D-8E5E-F6F6F6F6F6F6")!
    static let walk3 = UUID(uuidString: "C3C3C3C3-D4D4-4E5E-8F6F-070707070707")!
    static let deleted = UUID(uuidString: "DEADBEEF-0000-4000-8000-000000000001")!

    static func c(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }
    static func date(_ sinceReference: Double) -> Date { Date(timeIntervalSinceReferenceDate: sinceReference) }

    static let cities: [City] = [
        City(
            id: placeA, name: "Geographe", detail: "Busselton, Western Australia, Australia", osmId: 11688696, gridVersion: 2,
            boundary: Boundary(polygons: [GeoPolygon(
                outer: [c(-33.6409, 115.3586), c(-33.6409, 115.3721), c(-33.6301, 115.3721), c(-33.6301, 115.3586)],
                holes: [[c(-33.637, 115.362), c(-33.637, 115.364), c(-33.635, 115.363)]]
            )]),
            tiles: [Hex(q: -3, r: -7), Hex(q: 0, r: 0), Hex(q: 145554, r: -44178), Hex(q: -145554, r: 44178), Hex(q: Int32.max, r: Int32.min)],
            visited: [Hex(q: -3, r: -7), Hex(q: 145554, r: -44178)],
            roads: [
                RoadLine(kind: .road, points: [c(-33.639, 115.36), c(-33.638, 115.365)]),
                RoadLine(kind: .path, points: [c(-33.6355, 115.3601), c(-33.6352, 115.3609), c(-33.6349, 115.3612)]),
            ],
            stickers: ["geographe-jetty": Hex(q: -3, r: -7), "old-mill": Hex(q: 145554, r: -44178)],
            createdAt: date(800_000_000.5), updatedAt: date(812_345_678.25),
            tileCredits: [City.TileCredit(id: credit, at: date(-31_535_999.875), hexes: [Hex(q: -3, r: -7)])],
            lastWalked: LastWalked([Hex(q: -3, r: -7): 29_833_340, Hex(q: 145554, r: -44178): -1])
        ),
        City(
            id: placeB, name: "Bare place", detail: "", osmId: nil, gridVersion: nil,
            boundary: Boundary(polygons: [GeoPolygon(outer: [c(1.5, 2.5), c(1.5, 2.6), c(1.6, 2.6)], holes: [])]),
            tiles: [], visited: [], roads: nil, stickers: nil, createdAt: date(-1000.25), updatedAt: nil, tileCredits: nil
        ),
        City(
            id: placeC, name: "Empty streets", detail: "Somewhere", osmId: 1, gridVersion: 2,
            boundary: Boundary(polygons: []),
            tiles: [Hex(q: 1, r: -1)], visited: [], roads: [], stickers: [:], createdAt: date(0), updatedAt: date(0.001), tileCredits: []
        ),
    ]

    static let walks: [Walk] = [
        Walk(
            id: walk1, startedAt: date(812_345_000.125), endedAt: date(812_348_600.5),
            points: [
                TrackPoint(lat: -33.6391, lon: 115.3602, time: 1_790_000_000.25, accuracy: 4.5, speed: 1.35),
                TrackPoint(lat: -33.6389, lon: 115.3611, time: 1_790_000_007.75, accuracy: 12, speed: nil, wheels: false, still: true),
                TrackPoint(lat: -33.6387, lon: 115.362, time: 1_790_000_015, accuracy: -1, speed: 0, wheels: true, still: false),
            ],
            distance: 1234.5, gridVersion: 2, newTiles: 2,
            newTilesByPlace: [placeA.uuidString: 2],
            newTileHexesByPlace: [placeA.uuidString: [Hex(q: -3, r: -7), Hex(q: 145554, r: -44178)]],
            addedTilesByPlace: [placeA.uuidString: [Hex(q: -3, r: -7)]],
            automatic: nil
        ),
        // 1 a.m. on 1 January 2000: before Swift's reference date, so negative.
        Walk(
            id: walk2, startedAt: date(-31_618_799.25), endedAt: date(-31_615_200),
            points: [TrackPoint(lat: 51.5007, lon: -0.1246, time: 946_688_400.75, accuracy: 65)],
            distance: 0, gridVersion: nil, newTiles: 0, newTilesByPlace: nil, newTileHexesByPlace: nil, addedTilesByPlace: nil,
            automatic: false
        ),
        // An always-on walk still going.
        Walk(
            id: walk3, startedAt: date(812_400_000), endedAt: nil,
            points: [TrackPoint(lat: -33.64, lon: 115.37, time: 1_790_054_800, accuracy: 8, speed: 1.1)],
            distance: 42, gridVersion: 2, newTiles: 0, newTilesByPlace: [:], newTileHexesByPlace: [:], addedTilesByPlace: [:],
            automatic: true
        ),
    ]

    static let ledger = Ledger(
        purchases: [
            .init(id: "9C1F2E3D-0000-4000-8000-00000000000A", item: "spyglass", cost: 60, at: 1_790_000_000.5),
            .init(id: "P-2", item: "marker.paw", cost: 120, at: 1_790_000_001),
        ],
        claims: [.init(level: 2, choice: "shells.50"), .init(level: 3, choice: "spyglasses.2")],
        spyglasses: [.init(id: "S-1", secretId: "geographe-jetty", centre: [-33.6391, 115.3602], at: 1_790_000_100.125)],
        equipped: .init(marker: "marker.paw", trail: "trail.teal", clouds: "clouds.classic", cover: "cover.red",
                        celebration: "celebration.confetti", updatedAt: 1_790_000_200.75),
        offers: [.init(level: 2, choices: ["shells.50", "marker.paw", "spyglasses.2"]), .init(level: 3, choices: ["spyglasses.2"])]
    )

    static let stickers: [String: Date] = [
        "geographe-jetty": date(812_345_678.5),
        "old-mill": Progression.exploredSecretDate,
        "busselton-jetty": date(-86_400.5),
    ]

    static let syncState = SyncState(
        uploadedWalks: [walk1], uploadedPlaces: [placeA: date(812_345_678.25)], uploadedSecrets: ["geographe-jetty"],
        uploadedProgress: #"{"claims":[],"equipped":{}}"#, deletedPlaces: [deleted]
    )

    static let owner = "fixture-user"
}

/// Golden files for the Android app, which must read and write the same JSON
/// (shared/fixtures, design/android.md). The export only runs when asked:
/// `TEST_RUNNER_WALKIES_FIXTURES_OUT=$PWD/shared/fixtures/ios xcodebuild test ...`
struct FixtureExportTests {
    nonisolated static var outputFolder: URL? {
        ProcessInfo.processInfo.environment["WALKIES_FIXTURES_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// What the Android tests wrote, next to this file unless `WALKIES_FIXTURES_IN` says otherwise.
    nonisolated static var androidFolder: URL? {
        let folder = ProcessInfo.processInfo.environment["WALKIES_FIXTURES_IN"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "shared/fixtures/android")
        return files(in: folder).isEmpty ? nil : folder
    }

    /// Every file under a folder, as paths relative to it.
    nonisolated static func files(in folder: URL) -> [String] {
        guard let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        return all.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && $0.pathExtension == "json" }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "") }
            .sorted()
    }

    nonisolated static func scratch() -> URL {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesFixtureTests")
        return base.appending(path: UUID().uuidString)
    }

    @Test(.enabled(if: outputFolder != nil, "Set WALKIES_FIXTURES_OUT to write the fixtures"))
    func writeFixtures() throws {
        let out = try #require(Self.outputFolder)
        // Written by the real Store, exactly as the app saves them, then copied out.
        let root = Self.scratch()
        let store = Store(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        store.save(FixtureValues.cities)
        store.flush()
        for walk in FixtureValues.walks { store.save(walk) }
        store.save(stickers: FixtureValues.stickers)
        store.save(progress: FixtureValues.ledger)
        store.save(syncState: FixtureValues.syncState)
        store.save(owner: FixtureValues.owner)

        let written = Self.files(in: root)
        #expect(written.count == 7 + FixtureValues.walks.count)
        let fm = FileManager.default
        // Clear out old walk files, which are named by id.
        let oldWalks = out.appending(path: "walks")
        for name in (try? fm.contentsOfDirectory(atPath: oldWalks.path)) ?? [] where name.hasSuffix(".json") {
            try fm.removeItem(at: oldWalks.appending(path: name))
        }
        for name in written {
            let target = out.appending(path: name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: root.appending(path: name), to: target)
        }
    }

    @Test(.enabled(if: androidFolder != nil, "No Android fixtures in shared/fixtures/android yet"))
    func readAndroidFixtures() throws {
        let folder = try #require(Self.androidFolder)
        // Every file decodes strictly, by the app's own Codable types.
        let decoder = JSONDecoder()
        for name in Self.files(in: folder) {
            let data = try Data(contentsOf: folder.appending(path: name))
            switch name {
            case "cities.json": _ = try decoder.decode([City].self, from: data)
            case "roads.json": _ = try decoder.decode([String: [RoadLine]].self, from: data)
            case "stickers.json": _ = try decoder.decode([String: Date].self, from: data)
            case "progress.json": _ = try decoder.decode(Ledger.self, from: data)
            case "sync.json": _ = try decoder.decode(SyncState.self, from: data)
            case "owner.json": _ = try decoder.decode(String.self, from: data)
            case "data-version.json": #expect(try decoder.decode(Int.self, from: data) == HexGrid.version)
            case _ where name.hasPrefix("walks/"): _ = try decoder.decode(Walk.self, from: data)
            default: Issue.record("Nothing reads \(name)")
            }
        }

        // And the Store loads them as the same values. On a copy, since a file that
        // won't load gets moved aside.
        let root = Self.scratch()
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        #expect(store.loadCities() == FixtureValues.cities)
        let walks = store.loadWalks()
        try #require(walks.count == FixtureValues.walks.count)
        for expected in FixtureValues.walks {
            let walk = try #require(walks.first { $0.id == expected.id })
            #expect(walk.startedAt == expected.startedAt)
            #expect(walk.endedAt == expected.endedAt)
            #expect(walk.points == expected.points)
            #expect(walk.steps == expected.steps)
            var withSteps = walk
            withSteps.steps = 1234
            #expect(try JSONDecoder().decode(Walk.self, from: JSONEncoder().encode(withSteps)).steps == 1234)
            #expect(walk.distance == expected.distance)
            #expect(walk.gridVersion == expected.gridVersion)
            #expect(walk.newTiles == expected.newTiles)
            #expect(walk.newTilesByPlace == expected.newTilesByPlace)
            #expect(walk.newTileHexesByPlace == expected.newTileHexesByPlace)
            #expect(walk.addedTilesByPlace == expected.addedTilesByPlace)
            #expect(walk.automatic == expected.automatic)
        }
        #expect(store.loadStickers() == FixtureValues.stickers)
        #expect(store.loadProgress() == FixtureValues.ledger)
        let sync = store.loadSyncState()
        #expect(sync.uploadedWalks == FixtureValues.syncState.uploadedWalks)
        #expect(sync.uploadedPlaces == FixtureValues.syncState.uploadedPlaces)
        #expect(sync.uploadedSecrets == FixtureValues.syncState.uploadedSecrets)
        #expect(sync.uploadedProgress == FixtureValues.syncState.uploadedProgress)
        #expect(sync.deletedPlaces == FixtureValues.syncState.deletedPlaces)
        #expect(store.loadOwner() == FixtureValues.owner)
        #expect(!store.needsWorldGridReset)
    }
}
