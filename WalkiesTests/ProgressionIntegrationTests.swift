import CoreLocation
import Foundation
import Testing
@testable import Walkies

/// These tests also run on macOS through scripts/test-progression-model.sh. They
/// use real persistence and HTTP sync, with no location, account or network access.
@MainActor
@Suite(.serialized)
struct ProgressionIntegrationTests {
    func store() -> Store {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesProgressionTests")
        return Store(root: base.appending(path: UUID().uuidString))
    }

    func hex(q: Int32, r: Int32, origin: Coordinate = Coordinate(lat: 12.345, lon: 45.678)) -> Hex {
        let base = HexGrid.world.hex(containing: origin)
        return Hex(q: base.q + q, r: base.r + r)
    }

    func offset(in city: City) -> SIMD2<Double> {
        city.grid.centre(of: city.grid.hex(containing: city.boundary.centre))
    }

    func city(visited: Int = 10, origin: Coordinate = Coordinate(lat: 12.345, lon: 45.678)) -> City {
        let grid = HexGrid.world
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)].map { grid.projection.unproject(grid.centre(of: grid.hex(containing: origin)) + $0) }
        return City(name: "Test place", detail: "Tests",
                    boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: Set((0..<100).map { hex(q: Int32($0), r: 0, origin: origin) }),
                    visited: Set((0..<visited).map { hex(q: Int32($0), r: 0, origin: origin) }), roads: [])
    }

    func legacyWalk(_ n: Int, in city: City) -> Walk {
        let date = Date.now.addingTimeInterval(-Double(n + 1) * 86400)
        let points = [0.0, 15.0, 30.0].enumerated().map { index, x in
            let c = city.grid.projection.unproject(offset(in: city) + SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: date.timeIntervalSince1970 + Double(index) * 20,
                              accuracy: 5, speed: 1)
        }
        return Walk(startedAt: date, endedAt: date.addingTimeInterval(600), points: points, distance: 300, newTiles: 1)
    }

    func visit(_ model: AppModel, x: Double, seconds: Double) {
        let coordinate = model.cities[0].grid.projection.unproject(offset(in: model.cities[0]) + SIMD2(x, 0))
        model.tracker.onLocation?(CLLocation(coordinate: coordinate.cl, altitude: 0, horizontalAccuracy: 5,
                                            verticalAccuracy: 5, course: 90, speed: 1,
                                            timestamp: Date.now.addingTimeInterval(seconds)))
    }

    @Test func twoHundredLegacyWalksMigrateOnceOffMainAndNeverReplayAtWalkEndOrRelaunch() async {
        let store = store()
        defer { store.wipe() }
        let city = city()
        store.save([city])
        for n in 0..<200 { store.save(legacyWalk(n, in: city)) }
        let log = ReplayLog()
        let cutoff = Date.now.addingTimeInterval(-3600).timeIntervalSince1970
        CoverageTracer.replayObserver.set { points in
            if let first = points.first, abs(first.lat - 12.345) < 0.001, first.time < cutoff {
                log.record(onMain: Thread.isMainThread)
            }
        }
        defer { CoverageTracer.replayObserver.set(nil) }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        await model.waitForLastWalked()
        // Once each for the tile counts, and once more for when each tile was last
        // walked (the mist), both off the main thread.
        #expect(log.count == 400)
        #expect(log.mainCount == 0)
        #expect(store.loadWalks().allSatisfy { $0.newTilesByPlace != nil })
        model.startWalk()
        visit(model, x: -200, seconds: 0)
        visit(model, x: -100, seconds: 40)
        _ = model.balance
        model.endWalk()
        #expect(model.recap != nil)
        #expect(model.recap?.isRewatch == false)
        #expect(log.count == 400)
        #expect(log.mainCount == 0)
        let reopened = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await reopened.waitForHistory()
        await reopened.waitForLastWalked()
        _ = reopened.balance
        #expect(log.count == 400)
    }

    @Test func rewatchingAWalkFromHistoryAwardsAndChangesNothing() async throws {
        let store = store()
        defer { store.wipe() }
        let city = city()
        store.save([city])
        for n in 0..<3 { store.save(legacyWalk(n, in: city)) }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let ledger = model.ledger, xp = model.xp, balance = model.balance, picks = model.pendingPicks
        let earned = model.earnedBreakdown.total, stickers = model.stickerQueue.count
        let walks = model.walks.map(\.id), cities = model.cities.map(\.visited)
        model.replay(try #require(model.walks.first))
        for _ in 0..<500 where model.recap == nil { try await Task.sleep(for: .milliseconds(10)) }
        let recap = try #require(model.recap)
        #expect(recap.isRewatch)
        #expect(recap.shells == 0)
        #expect(recap.xp == 0)
        #expect(recap.questProgress.isEmpty)
        #expect(model.ledger == ledger)
        #expect(model.xp == xp)
        #expect(model.balance == balance)
        #expect(model.pendingPicks == picks)
        #expect(model.earnedBreakdown.total == earned)
        #expect(model.stickerQueue.count == stickers)
        #expect(model.walks.map(\.id) == walks)
        #expect(model.cities.map(\.visited) == cities)
    }

    @Test func uncoveringNonCountingTilesReusesHistoricalQuestRewards() async {
        let store = store()
        defer { store.wipe() }
        let city = city()
        // The simulator may already have always-on enabled from an app session.
        // Manual-walk fixtures must not inherit that preference.
        let previous = UserDefaults.standard.object(forKey: "alwaysOn")
        UserDefaults.standard.set(true, forKey: "alwaysOn")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "alwaysOn") }
            else { UserDefaults.standard.removeObject(forKey: "alwaysOn") }
        }
        store.save([city])
        for n in 0..<52 { store.save(legacyWalk(n * 7, in: city)) }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let before = model.earnedBreakdown
        let builds = model.progressionHistoryBuilds
        model.startWalk()
        #expect(model.activeWalk != nil)
        #expect(!model.autoWalkPending)
        visit(model, x: -300, seconds: 0)
        visit(model, x: -200, seconds: 40)
        let after = model.earnedBreakdown
        #expect(after.tiles > before.tiles)
        #expect(model.cities[0].tiles.count > city.tiles.count)
        #expect(model.progressionHistoryBuilds == builds)
        visit(model, x: -100, seconds: 80)
        _ = model.balance
        #expect(model.progressionHistoryBuilds == builds)
        model.endWalk()
        #expect(model.progressionHistoryBuilds == builds + 1)
    }

    @Test func resumedWalkKeepsFreshHexesAndCountingGridDenominator() async {
        let store = store()
        defer { store.wipe() }
        var city = city()
        let fresh: Set<Hex> = [hex(q: -1, r: 0)]
        city.tiles.formUnion(fresh)
        city.visited.formUnion(fresh)
        store.save([city])
        let start = Date.now.addingTimeInterval(-300)
        let points = [-200.0, 0.0].enumerated().map { index, x in
            let c = city.grid.projection.unproject(offset(in: city) + SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: start.timeIntervalSince1970 + Double(index) * 80,
                              accuracy: 5, speed: 1)
        }
        let walk = Walk(startedAt: start, points: points, distance: 200, newTiles: 1,
                        newTilesByPlace: [city.id.uuidString: 1], newTileHexesByPlace: [city.id.uuidString: fresh],
                        addedTilesByPlace: [city.id.uuidString: fresh], automatic: true)
        store.save(walk)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        #expect(model.activeWalk?.id == walk.id)
        model.endAutoWalk()
        #expect(model.recap?.earnings.breakdown.milestones == 0)
        #expect(model.recap?.shells == 1)
        #expect(model.recap?.places.first?.before == 0.1)
        #expect(model.walks.first?.newTilesByPlace?[city.id.uuidString] == 1)
        #expect(model.walks.first?.addedTilesByPlace?[city.id.uuidString] == fresh)
    }

    @Test func confirmedShortAutomaticOutingPersistsOnlyTileCredit() async throws {
        let store = store()
        defer { store.wipe() }
        store.save([city(visited: 0)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        // Each segment is within accuracy/speed/gap limits. Displacement from
        // the first stored fix reaches 150 m, but traced distance stays below 300 m.
        for (i, x) in [-400.0, -350, -300, -250, -200, -150].enumerated() {
            visit(model, x: x, seconds: Double(i) * 40)
        }
        #expect(model.activeWalk != nil)
        #expect(!model.autoWalkPending)
        let fresh = model.freshTiles[model.cities[0].id] ?? []
        #expect(!fresh.isEmpty)
        // The next fix closes the old outing through the normal inactivity path.
        visit(model, x: -100, seconds: 1000)
        #expect(model.activeWalk == nil)
        #expect(model.walks.isEmpty)
        #expect(model.recap == nil)
        #expect(store.loadWalks().isEmpty)
        #expect(model.cities[0].tileCredits?.first?.hexes == fresh)
        let reopened = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await reopened.waitForHistory()
        let credit = try #require(reopened.cities[0].tileCredits?.first)
        let week = Progression.week(containing: credit.at, calendar: Progression.calendar)
        let input = Progression.Inputs(cities: reopened.cities, walks: reopened.walks, now: credit.at.addingTimeInterval(1000))
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == Double(fresh.count))
        #expect(Progression.questProgress(.days3, week: week, inputs: input) == 0)
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 0)
    }

    @Test func midWalkLevelOfferFreezesBeforePurchaseAndOwnedChoiceBecomesBag() async throws {
        let store = store()
        defer { store.wipe() }
        var city = city(visited: 149)
        city.tiles = Set((0..<10000).map { hex(q: Int32($0), r: 0) })
        store.save([city])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.xp == 149)
        // A prior shell bag funds the purchase without itself changing XP.
        #expect(model.claim(level: 2, choice: Progression.shellBag))
        model.startWalk()
        visit(model, x: -300, seconds: 0)
        visit(model, x: -200, seconds: 40)
        #expect(model.level == 3)
        let offer = try #require(model.ledger.offers?.first { $0.level == 3 })
        let cosmetic = try #require(offer.choices.first { Progression.item($0)?.group != nil })
        #expect(model.buy(cosmetic))
        #expect(model.activeWalk != nil)
        #expect(model.picks(for: 3) == offer.choices)
        #expect(model.claim(level: 3, choice: cosmetic))
        #expect(model.ledger.claims.first { $0.level == 3 }?.choice == Progression.shellBag)
    }

    @Test func remoteTileCreditsMergeAndDeduplicateWithoutReplayingRoutes() async throws {
        let store = store()
        defer { store.wipe() }
        var city = city(visited: 10)
        let id = UUID(), now = Date.now.addingTimeInterval(-60)
        city.tileCredits = [.init(id: id, at: now, hexes: [hex(q: 0, r: 0)])]
        store.save([city])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var remote = city
        remote.tileCredits = [.init(id: UUID(), at: now, hexes: [hex(q: 0, r: 0), hex(q: 1, r: 0)])]
        await model.addRemote(cities: [remote], walks: [], progress: nil, secrets: [:])
        #expect(model.cities[0].tileCredits?.count == 2)
        let input = Progression.Inputs(cities: model.cities)
        let week = Progression.week(containing: now, calendar: Progression.calendar)
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == 2)
        let saved = try #require(store.loadCities().first)
        let savedIDs = Set(saved.tileCredits?.map(\.id) ?? [])
        #expect(savedIDs.contains(id))
    }

    @Test func pullMergesOwnershipBeforeFreezingMenusAndRefreshesOnce() async throws {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let city = city(visited: 100)
        let walks = (0..<20).map { legacyWalk($0, in: city) }
        var ledger = Ledger()
        ledger.purchases = [.init(item: "marker.sneaker", cost: 150, at: 0), .init(item: "trail.footprints", cost: 150, at: 0)]
        ledger.claims = [.init(level: 2, choice: Progression.shellBag)]
        let builds = model.progressionHistoryBuilds
        let server = TestSyncServer(ledger: ledger, cities: [city], walks: walks)
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(model.walks.count == 20)
        #expect(!model.pendingPicks.contains(2))
        #expect(model.progressionHistoryBuilds == builds + 1)
        for level in model.pendingPicks {
            #expect(!model.picks(for: level).contains("marker.sneaker"))
            #expect(!model.picks(for: level).contains("trail.footprints"))
        }
        #expect(store.loadWalks().allSatisfy { $0.newTilesByPlace != nil })
        engine.reset()
    }

    @Test func purchaseMadeWhilePullIsRunningGetsAnotherPush() async throws {
        let store = store()
        defer { store.wipe() }
        store.save([city(visited: 100)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let server = TestSyncServer(ledger: model.ledger, pauseSnapshot: true)
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        model.requestSync = { engine.schedule() }
        let task = Task { await engine.sync() }
        await server.waitForSnapshot()
        #expect(model.buy("spyglass"))
        // Also exercise the direct sync guard while another sync is suspended.
        await engine.sync()
        // Keep the first pull open past the original two-second debounce. Without
        // the pending flag that scheduled attempt runs, hits !running and is lost.
        try await Task.sleep(for: .milliseconds(2200))
        await server.resumeSnapshot()
        await task.value
        for _ in 0..<200 {
            if await server.hasPurchase("spyglass"), engine.status == .idle { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await server.hasPurchase("spyglass"))
        #expect(engine.waiting == 0)
        model.requestSync = nil
        engine.reset()
    }

    @Test func retainedServerWalkDropsOldHexesAndUploadsRebuiltCoverage() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city(visited: 0)
        var old = legacyWalk(0, in: place)
        old.gridVersion = nil
        old.newTiles = 999
        old.newTilesByPlace = [place.id.uuidString: 999]
        old.newTileHexesByPlace = [place.id.uuidString: [Hex(q: 999, r: 999)]]
        old.addedTilesByPlace = old.newTileHexesByPlace
        let server = TestSyncServer(cities: [place], walks: [old])
        let client = mockClient(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status == .idle)
        let rebuilt = try #require(model.walks.first)
        #expect(rebuilt.gridVersion == 2)
        #expect(rebuilt.points == old.points)
        #expect(rebuilt.newTiles == 1)
        #expect(rebuilt.newTileHexesByPlace?[place.id.uuidString] == [hex(q: 0, r: 0)])
        #expect(rebuilt.addedTilesByPlace == nil)
        #expect(!store.loadSyncState().uploadedWalks.contains(old.id))
        await engine.sync()
        #expect(await server.calls.filter { $0 == "sync:saveWalk" }.count == 1)
        #expect(store.loadSyncState().uploadedWalks.contains(old.id))
        engine.reset()
    }

    /// Feedback: "I can't re-equip something I have bought". Buy a trail, switch back
    /// to the free one and between owned ones, through sync on two phones.
    @Test func boughtAndDefaultCosmeticsCanBeSwitchedFreelyThroughSync() async throws {
        let store = store()
        let otherStore = self.store()
        defer { store.wipe(); otherStore.wipe() }
        store.save([city(visited: 100)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        let server = TestSyncServer()
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })

        #expect(model.buy("trail.footprints"))
        #expect(model.equipped.trail == "trail.footprints")
        await engine.sync()
        #expect(model.equip("trail.teal"))
        #expect(model.equipped.trail == "trail.teal")
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(model.equipped.trail == "trail.teal")
        #expect(await server.ledger.equipped.trail == "trail.teal")

        #expect(model.buy("trail.sparkles"))
        #expect(model.equip("trail.footprints"))
        await engine.sync()
        #expect(model.equipped.trail == "trail.footprints")
        #expect(await server.ledger.equipped.trail == "trail.footprints")
        engine.reset()

        // The other phone pulls the choice, changes it, and the first phone follows.
        let other = AppModel(store: otherStore, servicesEnabled: false, alwaysOn: false)
        await other.waitForHistory()
        let otherEngine = SyncEngine(model: other, store: otherStore, isSignedIn: { true }, makeClient: { client })
        await otherEngine.sync()
        #expect(other.equipped.trail == "trail.footprints")
        #expect(other.owned.isSuperset(of: ["trail.teal", "trail.footprints", "trail.sparkles"]))
        #expect(other.equip("trail.sparkles"))
        await otherEngine.sync()
        otherEngine.reset()
        let again = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await again.sync()
        #expect(model.equipped.trail == "trail.sparkles")
        #expect(model.equip("trail.teal"))
        await again.sync()
        #expect(model.equipped.trail == "trail.teal")
        #expect(await server.ledger.equipped.trail == "trail.teal")
        again.reset()
    }

    /// Every cosmetic group switches between a bought look and its free default, both ways through sync.
    @Test func everyGroupSwitchesBetweenOwnedAndDefaultLooksThroughSync() async throws {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var ledger = Ledger()
        ledger.purchases = Progression.catalog.filter { $0.group != nil && !$0.isFree }.map { .init(item: $0.id, cost: 0, at: 0) }
        let server = TestSyncServer(ledger: ledger)
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        for group in Progression.Group.allCases {
            let looks = Progression.catalog.filter { $0.group == group }.map(\.id)
            #expect(model.owned.isSuperset(of: looks))
            for look in looks.dropFirst() + [looks[0]] {
                #expect(model.equip(look))
                await engine.sync()
                #expect(model.equipped[group] == look)
                #expect(await server.ledger.resolvedEquipment[group] == look)
            }
        }
        engine.reset()
    }

    /// Places built before busy roads were left out get their street tiles redone once
    /// (StreetUpdateTest.kt), keeping what you've done.
    @Test func oldPlacesLoseUnwalkableRoadTilesOnceAndKeepWhatYouveDone() async throws {
        let store = store()
        defer { store.wipe() }
        let grid = HexGrid.world
        let origin = grid.centre(of: grid.hex(containing: Coordinate(lat: 12.345, lon: 45.678)))
        func at(_ x: Double, _ y: Double) -> Coordinate { grid.projection.unproject(origin + SIMD2(x, y)) }
        func line(_ y: Double) -> [Coordinate] { stride(from: -800.0, through: 800, by: 50).map { at($0, y) } }
        let boundary = Boundary(polygons: [GeoPolygon(outer: [at(-1000, -1000), at(1000, -1000), at(1000, 1000), at(-1000, 1000), at(-1000, -1000)], holes: [])])
        let street = OSMWay(tags: ["highway": "residential"], points: line(300))
        let highway = OSMWay(tags: ["highway": "trunk"], points: line(-300))
        let inside = City.hexes(inside: BoundaryShape(boundary, projection: grid.projection), grid: grid)
        let highwayTiles = CityBuilder.streetTiles(from: [highway], inside: inside).sorted { $0.q < $1.q }
        let place = PlaceResult(id: 1, name: "Busselton", detail: "Tests", kind: "suburb", boundary: boundary, area: 4_000_000, osmId: 123)
        var old = CityBuilder.build(from: place, ways: [street, highway], walks: [])
        old.visited = Set(highwayTiles.prefix(3))
        old.tileCredits = [.init(id: UUID(), at: Date(timeIntervalSince1970: 1_790_000_000), hexes: [highwayTiles[2]])]
        old.updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(old.streetsVersion == nil)
        store.save([old])

        let ring = boundary.polygons[0].outer.map { "[\($0.lon),\($0.lat)]" }.joined(separator: ",")
        let points = street.points.map { "[\($0.lat),\($0.lon)]" }.joined(separator: ",")
        let file = Data(#"{"boundary":[[[\#(ring)]]],"ways":[{"highway":"residential","points":[\#(points)]}]}"#.utf8)
        let server = TestSyncServer(streets: file, streetsVersion: 2)
        let client = mockClient(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.makePlaceClient = { client }
        var synced = 0
        model.requestSync = { synced += 1 }
        let before = try #require(model.cities.first)

        await model.updateStreets()
        let city = try #require(model.cities.first)
        let streetTiles = CityBuilder.streetTiles(from: [street], inside: inside)
        #expect(city.streetsVersion == 2)
        #expect(city.visited == before.visited)
        #expect(city.tileCredits == old.tileCredits)
        // Secrets are placed at launch; one hides on the highway and keeps its tile.
        #expect(city.stickers == before.stickers)
        #expect((before.stickers ?? [:]).values.contains { !streetTiles.contains($0) })
        // The street's tiles, plus the walked, credited and secret highway tiles. No others.
        #expect(city.tiles == streetTiles.union(before.visited).union((before.stickers ?? [:]).values))
        #expect(city.tiles.count < before.tiles.count)
        #expect(city.progress > before.progress)
        // The rest of the highway is no-path now, so it clears beside walked tiles.
        #expect(city.cloudCover().clear.count > before.visited.count)
        #expect(city.lastChanged > old.lastChanged)
        #expect(synced == 1)
        store.flush()
        #expect(store.loadCities().first?.tiles == city.tiles)
        #expect(store.loadCities().first?.streetsVersion == 2)

        // Once per place.
        await model.updateStreets()
        #expect(await server.calls.filter { $0 == "places:get" }.count == 1)

        // A phone that hasn't updated yet can't bring the highway back.
        var stale = old
        stale.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        await model.addRemote(cities: [stale], walks: [], progress: nil, secrets: [:])
        #expect(model.cities.first?.tiles == city.tiles)
        #expect(model.cities.first?.streetsVersion == 2)
        // And an updated copy from another phone replaces an old one's street tiles.
        let otherStore = self.store()
        defer { otherStore.wipe() }
        otherStore.save([old])
        let other = AppModel(store: otherStore, servicesEnabled: false, alwaysOn: false)
        await other.waitForHistory()
        var updated = city
        updated.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        await other.addRemote(cities: [updated], walks: [], progress: nil, secrets: [:])
        #expect(other.cities.first?.tiles == city.tiles)
        #expect(other.cities.first?.streetsVersion == 2)
    }

    @Test func anOlderServerLeavesPlacesForLater() async throws {
        let store = store()
        defer { store.wipe() }
        var place = city(visited: 3)
        place.osmId = 123
        store.save([place])
        let ring = place.boundary.polygons[0].outer.map { "[\($0.lon),\($0.lat)]" }.joined(separator: ",")
        let server = TestSyncServer(streets: Data(#"{"boundary":[[[\#(ring)]]],"ways":[]}"#.utf8), streetsVersion: nil)
        let client = mockClient(server)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.makePlaceClient = { client }
        let before = model.cities
        await model.updateStreets()
        #expect(model.cities == before)
        #expect(await server.calls.contains("places:get"))
    }

    @Test func rejectedProgressDoesNotBlockSecretUploads() async {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.addRemoteSecrets(["one": .now])
        let server = TestSyncServer(rejectProgress: true)
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        model.addRemoteSecrets(["two": .now])
        await engine.sync()
        #expect(await server.savedSecrets == Set(["one", "two"]))
        let calls = await server.calls
        #expect(calls.prefix(2) == ["sync:saveSecrets", "sync:saveProgress"])
        #expect(engine.status != .idle)
        engine.reset()
    }

    @Test func overlappingPlaceFindsSecretsWithoutShellsAndSentinelSurvivesSync() async throws {
        let store = store()
        defer { store.wipe() }
        let entry = try #require(LoreLibrary.all.first { $0.place != nil })
        let origin = try #require(entry.place?.coordinate)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.add(city(visited: 1, origin: origin))
        #expect(model.foundStickers[entry.id] == Progression.exploredSecretDate)
        #expect(model.earnedBreakdown.secrets == 0)
        let week = Progression.week(containing: .now, calendar: Progression.calendar)
        #expect(Progression.questProgress(.secret, week: week, inputs: .init(foundSecrets: model.foundStickers)) == 0)
        let server = TestSyncServer()
        let client = mockClient(server)
        let engine = SyncEngine(model: model, store: store, isSignedIn: { true }, makeClient: { client })
        await engine.sync()
        #expect(engine.status == .idle)
        #expect(model.foundStickers[entry.id] == Progression.exploredSecretDate)
        #expect(model.earnedBreakdown.secrets == 0)
        // A real discovery from another phone still wins the earliest-date merge.
        model.addRemoteSecrets([entry.id: .now])
        #expect(model.earnedBreakdown.secrets == 10)
        engine.reset()
    }

    @Test func nearbyStreetCacheWarmsOncePerListAfterSignIn() async throws {
        let store = store()
        let home = city(visited: 0)
        store.save([home])
        let neighbour = PlaceResult(id: 1, name: "Next suburb", detail: "Tests", kind: "suburb", boundary: home.boundary, area: 1_000_000, osmId: 123)
        func saveList(_ places: [PlaceResult]) {
            let c = home.boundary.centre
            store.save(nearby: NearbyPlaces(south: c.lat - 1, west: c.lon - 1, north: c.lat + 1, east: c.lon + 1, fetchedAt: .now, places: places))
        }
        saveList([neighbour, neighbour])
        let server = TestSyncServer()
        let client = mockClient(server)
        let model = AppModel(store: store, servicesEnabled: true, alwaysOn: false)
        await model.waitForHistory()
        var signedIn = false
        model.makePlaceClient = { signedIn ? client : nil }
        model.refreshNeighbours()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await server.warmedLists.isEmpty)
        signedIn = true
        model.refreshNeighbours()
        for _ in 0..<100 {
            if await server.warmedLists.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        model.refreshNeighbours()
        model.refreshNeighbours()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await server.warmedLists == [[123]])
        var other = neighbour
        other.osmId = 456
        saveList([neighbour, other])
        model.refreshNeighbours()
        for _ in 0..<100 {
            if await server.warmedLists.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.warmedLists == [[123], [123, 456]])
    }

    private func mockClient(_ server: TestSyncServer) -> ConvexClient {
        MockSyncProtocol.server = server
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSyncProtocol.self]
        return ConvexClient(token: nil, session: URLSession(configuration: configuration))
    }
}

private nonisolated final class ReplayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var replays = 0
    private var mainReplays = 0
    func record(onMain: Bool) {
        lock.lock()
        replays += 1
        if onMain { mainReplays += 1 }
        lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return replays }
    var mainCount: Int { lock.lock(); defer { lock.unlock() }; return mainReplays }
}

private actor TestSyncServer {
    var ledger: Ledger
    var cities: [City]
    var walks: [Walk]
    var rejectProgress: Bool
    var pauseSnapshot: Bool
    var calls: [String] = []
    var warmedLists: [[Int]] = []
    var savedSecrets: Set<String> = []
    var dates: [String: Double] = [:]
    var snapshotStarted = false
    var snapshotWaiter: CheckedContinuation<Void, Never>?
    var snapshotResume: CheckedContinuation<Void, Never>?

    var streets: Data?
    var streetsVersion: Int?

    init(ledger: Ledger = Ledger(), cities: [City] = [], walks: [Walk] = [], rejectProgress: Bool = false, pauseSnapshot: Bool = false,
         streets: Data? = nil, streetsVersion: Int? = nil) {
        self.streets = streets
        self.streetsVersion = streetsVersion
        self.ledger = ledger
        self.cities = cities
        self.walks = walks
        self.rejectProgress = rejectProgress
        self.pauseSnapshot = pauseSnapshot
    }

    func waitForSnapshot() async {
        if !snapshotStarted { await withCheckedContinuation { snapshotWaiter = $0 } }
    }
    func resumeSnapshot() { pauseSnapshot = false; snapshotResume?.resume(); snapshotResume = nil }
    func hasPurchase(_ item: String) -> Bool { ledger.purchases.contains { $0.item == item } }

    func respond(_ request: URLRequest) async throws -> Data {
        let url = request.url!
        if url.host == "files.walkies.test" {
            if url.lastPathComponent == "streets", let streets { return streets }
            if let city = cities.first(where: { url.lastPathComponent == $0.id.uuidString }) { return try JSONEncoder().encode(city) }
            return try JSONEncoder().encode(walks.first { url.lastPathComponent == $0.id.uuidString }!)
        }
        if url.path == "/upload" { return Data(#"{"storageId":"test-file"}"#.utf8) }
        let body: Data
        if let data = request.httpBody { body = data }
        else {
            let stream = request.httpBodyStream!
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
            body = data
        }
        let call = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let path = call["path"] as! String
        let args = call["args"] as! [String: Any]
        calls.append(path)
        if ["sync:savePlace", "sync:saveWalk", "sync:saveProgress", "sync:saveSecrets", "sync:deletePlace"].contains(path) {
            #expect(args["gridVersion"] as? Int == 2)
        }
        var value: Any = NSNull()
        switch path {
        case "teams:myTeams": value = [] as [String]
        case "places:warm": warmedLists.append(args["osmIds"] as! [Int])
        case "places:get":
            var file: [String: Any] = ["url": "https://files.walkies.test/streets", "fetchedAt": 1_790_000_000_000.0]
            if let streetsVersion { file["version"] = streetsVersion }
            value = file
        case "sync:generateUploadUrl": value = "https://sync.walkies.test/upload"
        case "sync:saveProgress":
            if rejectProgress { return Data(#"{"status":"error","errorMessage":"Rejected ledger"}"#.utf8) }
            let incoming = try JSONDecoder().decode(Ledger.self, from: Data((args["ledger"] as! String).utf8))
            ledger = ledger.merged(with: incoming)
        case "sync:saveSecrets":
            for secret in args["secrets"] as! [[String: Any]] {
                let id = secret["secretId"] as! String, date = secret["foundAt"] as! Double
                savedSecrets.insert(id)
                dates[id] = min(dates[id] ?? .infinity, date)
            }
        case "sync:snapshot":
            snapshotStarted = true
            snapshotWaiter?.resume()
            snapshotWaiter = nil
            if pauseSnapshot { await withCheckedContinuation { snapshotResume = $0 } }
            value = [
                "places": cities.map { ["clientId": $0.id.uuidString, "updatedAt": $0.lastChanged.ms, "url": "https://files.walkies.test/\($0.id.uuidString)"] },
                "walks": walks.map { ["clientId": $0.id.uuidString, "url": args["walkUrls"] as? Bool == false ? NSNull() : "https://files.walkies.test/\($0.id.uuidString)"] as [String: Any] },
                "secrets": dates.map { ["secretId": $0.key, "foundAt": $0.value] },
                "progress": String(decoding: try JSONEncoder().encode(ledger), as: UTF8.self),
            ] as [String: Any]
        case "sync:walkUrls":
            let ids = Set(walks.map(\.id.uuidString))
            value = (args["clientIds"] as! [String]).filter(ids.contains).map { ["clientId": $0, "url": "https://files.walkies.test/\($0)"] }
        default: break
        }
        return try JSONSerialization.data(withJSONObject: ["status": "success", "value": value])
    }
}

private nonisolated final class MockSyncProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: TestSyncServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let server = Self.server!
        Task {
            do {
                let data = try await server.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
