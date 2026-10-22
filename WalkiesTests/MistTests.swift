import CoreLocation
import Foundation
import Testing
@testable import Walkies

/// Walked tiles not walked again for a while go misty. Mist is only a look: it never
/// changes tiles, %, shells, XP, levels or quests.
@MainActor
@Suite(.serialized)
struct MistTests {
    // Away from ProgressionIntegrationTests, which counts routes traced near its own spot.
    let origin = Coordinate(lat: -22.5, lon: 133.75)
    let day = 86_400.0

    func hex(_ q: Int32, _ r: Int32 = 0) -> Hex {
        let base = HexGrid.world.hex(containing: origin)
        return Hex(q: base.q + q, r: base.r + r)
    }

    func store() -> Store {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesMistTests")
        return Store(root: base.appending(path: UUID().uuidString))
    }

    /// Street tiles q 0 to 19 along one row, the first `visited` of them walked.
    func city(visited: Int = 10) -> City {
        let grid = HexGrid.world
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)]
            .map { grid.projection.unproject(grid.centre(of: hex(0)) + $0) }
        return City(name: "Misty", detail: "Tests",
                    boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: Set((0..<20).map { hex(Int32($0)) }),
                    visited: Set((0..<visited).map { hex(Int32($0)) }), roads: [])
    }

    /// A point `x` metres east of the middle of tile q.
    func point(_ q: Int32, x: Double = 0) -> Coordinate {
        let grid = HexGrid.world
        return grid.projection.unproject(grid.centre(of: hex(q)) + SIMD2(x, 0))
    }

    /// A walk across tile q, `daysAgo` days ago.
    func walk(across q: Int32, daysAgo: Double) -> Walk {
        let start = Date.now.addingTimeInterval(-daysAgo * day)
        let points = [-20.0, 0, 20].enumerated().map { i, x in
            let c = point(q, x: x)
            return TrackPoint(lat: c.lat, lon: c.lon, time: start.timeIntervalSince1970 + Double(i) * 15, accuracy: 5, speed: 1.3)
        }
        return Walk(startedAt: start, endedAt: start.addingTimeInterval(60), points: points, distance: 40, newTiles: 0)
    }

    func minute(daysAgo: Double) -> Int { Mist.minute(Date.now.timeIntervalSince1970 - daysAgo * day) }

    // MARK: The record

    @Test func savedAsTriplesAndOldSavesHaveNone() throws {
        var city = city()
        city.lastWalked = LastWalked([hex(1): 29_000_000, hex(0): 28_999_999])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(city)) as? [String: Any]
        let saved = try #require(json?["lastWalked"] as? [[Int]])
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.count == 3 })
        #expect(Set(saved.map(\.[2])) == [29_000_000, 28_999_999])
        #expect(try JSONDecoder().decode(City.self, from: JSONEncoder().encode(city)) == city)

        var old = json ?? [:]
        old["lastWalked"] = nil
        let decoded = try JSONDecoder().decode(City.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.lastWalked == nil)
    }

    @Test func walkingNotesOnlyTilesThatCountAndClearsMist() {
        var city = city(visited: 3)
        city.lastWalked = LastWalked([hex(0): minute(daysAgo: 90), hex(1): minute(daysAgo: 0.01)])
        let now = Date.now.timeIntervalSince1970
        // Tile 0 was misty, tile 1 walked a quarter of an hour ago, tile 2 never noted,
        // and the point off the end of the row isn't a tile you've visited.
        let points = [point(0), point(1), point(2), point(-5)]
        let result = city.noteWalked(points, at: now, mistDays: 60)
        #expect(result.changed)
        #expect(result.cleared == [hex(0)])
        #expect(city.lastWalked?[hex(0)] == Mist.minute(now))
        #expect(city.lastWalked?[hex(1)] == minute(daysAgo: 0.01))  // too recent to bother rewriting
        #expect(city.lastWalked?[hex(2)] == Mist.minute(now))
        #expect(city.lastWalked?[hex(-5)] == nil)
        // Nothing that counts moved.
        #expect(city.visited.count == 3)
        #expect(city.tiles.count == 20)

        let again = city.noteWalked(points, at: now + 60, mistDays: 60)
        #expect(!again.changed)
    }

    @Test func mergingKeepsTheLaterDateForEachTile() {
        var mine = city()
        mine.lastWalked = LastWalked([hex(0): 100, hex(1): 500])
        var theirs = city()
        theirs.lastWalked = LastWalked([hex(0): 300, hex(1): 200, hex(2): 50])
        #expect(mine.lastWalked?.hasLater(than: theirs.lastWalked) == true)
        mine.mergeLastWalked(theirs.lastWalked)
        #expect(mine.lastWalked == LastWalked([hex(0): 300, hex(1): 500, hex(2): 50]))
        #expect(mine.lastWalked?.hasLater(than: theirs.lastWalked) == true)
        #expect(theirs.lastWalked?.hasLater(than: mine.lastWalked) == false)

        var fresh = city()
        fresh.mergeLastWalked(nil)
        #expect(fresh.lastWalked == nil)
    }

    @Test func filledInFromTheWalksAndCredits() {
        var city = city(visited: 6)
        let creditDate = Date.now.addingTimeInterval(-10 * day)
        city.tileCredits = [City.TileCredit(id: UUID(), at: creditDate, hexes: [hex(4)])]
        let older = walk(across: 2, daysAgo: 40)
        let newer = walk(across: 2, daysAgo: 5)
        let other = walk(across: 3, daysAgo: 70)
        let found = City.lastWalked(for: [city], from: [newer, older, other])[city.id]
        // When the walk passed it, not when it started or the older walk did.
        let crossed = found?[hex(2)] ?? 0
        #expect(crossed >= Mist.minute(newer.points[0].time) && crossed <= Mist.minute(newer.points[2].time))
        let long = found?[hex(3)] ?? 0
        #expect(long >= Mist.minute(other.points[0].time) && long <= Mist.minute(other.points[2].time))
        #expect(found?[hex(4)] == Mist.minute(creditDate.timeIntervalSince1970))
        // Tiles nobody walked, on record or at all, have no date.
        #expect(found?[hex(0)] == nil)
        #expect(found?[hex(10)] == nil)
    }

    @Test func noPathTilesClearedForFreeNeverMist() {
        // One street tile, walked long ago, surrounded by bush that cleared beside it.
        var city = city(visited: 1)
        city.tiles = [hex(0)]
        city.lastWalked = City.lastWalked(for: [city], from: [walk(across: 0, daysAgo: 100)])[city.id]
        let cover = city.cloudCover()
        #expect(cover.clear.contains(hex(1)))
        let misty = Mist.tiles(in: [city], now: .now, days: 60)
        #expect(misty == [hex(0)])
        let field = CloudField(cities: [city], mistAt: .now, mistDays: 60)
        #expect(Set(field.mist.map(\.tile.hex)) == [hex(0)])
    }

    @Test func mistyTilesForADateAndThreshold() {
        var a = city(visited: 4)
        a.lastWalked = LastWalked([hex(0): minute(daysAgo: 61), hex(1): minute(daysAgo: 59), hex(2): minute(daysAgo: 200)])
        #expect(Mist.tiles(in: [a], now: .now, days: 60) == [hex(0), hex(2)])
        #expect(Mist.tiles(in: [a], now: .now, days: 100) == [hex(2)])
        #expect(Mist.tiles(in: [a], now: .now.addingTimeInterval(2 * day), days: 60) == [hex(0), hex(1), hex(2)])
        // About a minute and a half: `-mistDays 0.001`.
        var b = city(visited: 2)
        b.lastWalked = LastWalked([hex(0): minute(daysAgo: 0.002), hex(1): Mist.minute(Date.now.timeIntervalSince1970)])
        #expect(Mist.tiles(in: [b], now: .now, days: 0.001) == [hex(0)])

        // A tile on the border of two places goes by whichever saw you last.
        var c = city(visited: 1)
        c.id = UUID()
        c.lastWalked = LastWalked([hex(0): minute(daysAgo: 1)])
        #expect(Mist.tiles(in: [a, c], now: .now, days: 60) == [hex(2)])
        // Without a date, never misty; without a visit, never either.
        var d = city(visited: 0)
        d.lastWalked = LastWalked([hex(0): minute(daysAgo: 300)])
        #expect(Mist.tiles(in: [d], now: .now, days: 60).isEmpty)
        #expect(CloudField(cities: [a]).mist.isEmpty)
    }

    @Test func mistNeverChangesProgress() {
        let walks = [walk(across: 1, daysAgo: 90), walk(across: 2, daysAgo: 3)]
        let plain = city()
        var misty = plain
        misty.lastWalked = City.lastWalked(for: [plain], from: walks)[plain.id]
        #expect(!Mist.tiles(in: [misty], now: .now, days: 60).isEmpty)
        #expect(misty.progress == plain.progress)
        #expect(misty.cloudCover().clear == plain.cloudCover().clear)
        #expect(misty.cloudCover().clouded == plain.cloudCover().clouded)
        let before = Progression.state(Progression.Inputs(cities: [plain], walks: walks))
        let after = Progression.state(Progression.Inputs(cities: [misty], walks: walks))
        #expect(before.earned == after.earned)
        #expect(before.xp == after.xp)
        #expect(before.level == after.level)
        #expect(before.quests.map(\.progress) == after.quests.map(\.progress))
    }

    // MARK: The app

    @Test func launchFillsInDatesFromSavedWalksOnce() async {
        let store = store()
        defer { store.wipe() }
        let city = city()
        store.save([city])
        let old = walk(across: 3, daysAgo: 80)
        store.save(old)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        await model.waitForLastWalked()
        let walked = model.cities[0].lastWalked
        #expect(walked != nil)
        #expect((walked?[hex(3)] ?? 0) >= Mist.minute(old.startedAt.timeIntervalSince1970))
        #expect(walked?[hex(5)] == nil)
        #expect(model.cities[0].visited == city.visited)
        #expect(Set(model.cloudField.mist.map(\.tile.hex)) == [hex(3)])
        store.flush()
        #expect(store.loadCities().first?.lastWalked == walked)
    }

    @Test func walkingThroughMistClearsItAndChangesNothingElse() async {
        let store = store()
        defer { store.wipe() }
        var city = city()
        city.lastWalked = LastWalked(Dictionary(uniqueKeysWithValues: (0..<10).map { (hex(Int32($0)), minute(daysAgo: 100)) }))
        store.save([city])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let xp = model.xp
        let progress = model.cities[0].progress
        #expect(Mist.tiles(in: model.cities, now: .now, days: 60).contains(hex(0)))
        model.startWalk()
        for (i, x) in [-20.0, 0, 20].enumerated() {
            let c = point(0, x: x)
            model.tracker.onLocation?(CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                                course: 90, speed: 1.3, timestamp: Date.now.addingTimeInterval(Double(i) * 15)))
        }
        let misty = Mist.tiles(in: model.cities, now: .now, days: 60)
        #expect(!misty.contains(hex(0)))
        #expect(misty.contains(hex(5)))
        #expect(model.cities[0].visited == city.visited)
        #expect(model.cities[0].tiles == city.tiles)
        #expect(model.cities[0].progress == progress)
        #expect(model.xp == xp)
    }

    @Test func pullingAPlaceKeepsTheLaterDates() async {
        let store = store()
        defer { store.wipe() }
        var city = city()
        city.lastWalked = LastWalked([hex(0): 1000, hex(1): 5000])
        store.save([city])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var remote = city
        remote.lastWalked = LastWalked([hex(0): 2000, hex(1): 4000, hex(2): 3000])
        await model.addRemote(cities: [remote], walks: [], progress: nil, secrets: [:])
        #expect(model.cities[0].lastWalked == LastWalked([hex(0): 2000, hex(1): 5000, hex(2): 3000]))

        var older = city
        older.lastWalked = nil
        await model.addRemote(cities: [older], walks: [], progress: nil, secrets: [:])
        #expect(model.cities[0].lastWalked == LastWalked([hex(0): 2000, hex(1): 5000, hex(2): 3000]))
    }
}
