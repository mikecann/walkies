import CoreLocation
import Foundation
import Testing
@testable import Walkies

/// Always-on walks, deleting places, secrets found under old tiles and launching
/// before the phone's been unlocked.
@MainActor
@Suite(.serialized)
struct ModelFixesTests {
    func store() -> Store {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesModelFixesTests")
        return Store(root: base.appending(path: UUID().uuidString))
    }

    func city(_ name: String = "Test place", visited: Int = 0, origin: Coordinate = Coordinate(lat: 12.345, lon: 45.678)) -> City {
        let grid = HexGrid.world
        let base = grid.hex(containing: origin)
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)]
            .map { grid.projection.unproject(grid.centre(of: base) + $0) }
        return City(name: name, detail: "Tests",
                    boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: Set((0..<100).map { Hex(q: base.q + Int32($0), r: base.r) }),
                    visited: Set((0..<visited).map { Hex(q: base.q + Int32($0), r: base.r) }), roads: [])
    }

    func coordinate(in city: City, x: Double) -> Coordinate {
        let centre = city.grid.centre(of: city.grid.hex(containing: city.boundary.centre))
        return city.grid.projection.unproject(centre + SIMD2(x, 0))
    }

    func visit(_ model: AppModel, in city: City, x: Double, seconds: Double) {
        let c = coordinate(in: city, x: x)
        model.tracker.onLocation?(CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: 5,
                                            verticalAccuracy: 5, course: 90, speed: 1,
                                            timestamp: Date.now.addingTimeInterval(seconds)))
    }

    @Test func secretsUnderTilesYouveWalkedAreSummedUpNotPoppedUp() async throws {
        let store = store()
        defer { store.wipe() }
        let entry = try #require(LoreLibrary.all.first { $0.place != nil })
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.add(city(visited: 1, origin: try #require(entry.place?.coordinate)))
        #expect(model.foundStickers[entry.id] != nil)
        #expect(model.stickerQueue.isEmpty)
        #expect(model.secretsAlreadyWalked >= 1)
    }

    @Test func anAutomaticWalkKeepsTheFixItStartedFrom() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city()
        store.save([place])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        let xs = [-400.0, -350, -300, -250, -200, -150, -100]
        for (i, x) in xs.enumerated() { visit(model, in: place, x: x, seconds: Double(i) * 40) }
        let walk = try #require(model.activeWalk)
        #expect(!model.autoWalkPending)
        #expect(walk.points.count == xs.count)
        #expect(walk.points[0].coordinate.distance(to: coordinate(in: place, x: -400)) < 1)
        #expect(abs(walk.startedAt.timeIntervalSince1970 - walk.points[0].time) < 0.001)
        // Recording and replaying agree on the distance and the tiles.
        #expect(abs(walk.distance - CoverageTracer.distance(for: walk.points)) < 0.01)
        let straight = coordinate(in: place, x: -400).distance(to: coordinate(in: place, x: -100))
        #expect(abs(walk.distance - straight) < 1)
        let samples = CoverageTracer.samples(for: walk.points)
        let traced = Set(samples.map { place.grid.hex(containing: $0) })
        #expect((model.freshTiles[place.id] ?? []).isSubset(of: traced))
        // The route starts with the first segment, a sample's spacing from the first fix.
        #expect(try #require(samples.first).distance(to: coordinate(in: place, x: -400)) <= CoverageTracer.spacing)
    }

    @Test func aWalkHoursAfterTheLastFixStartsWhenYouHeadOut() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city()
        store.save([place])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        // One fix just after a restart, then the GPS rests for five hours (30 Oct 2026).
        let start = Date.now
        visit(model, in: place, x: -400, seconds: 0)
        let later = 5 * 3600.0
        for (i, x) in [-280.0, -230, -180, -130, -80, -30].enumerated() {
            visit(model, in: place, x: x, seconds: later + Double(i) * 40)
        }
        let walk = try #require(model.activeWalk)
        #expect(!model.autoWalkPending)
        #expect(walk.startedAt.timeIntervalSince(start) > later - 1)
        #expect(try #require(walk.points.first).coordinate.distance(to: coordinate(in: place, x: -280)) < 1)
    }

    @Test func anAutomaticPauseKeepsTheSameWalkAndResumesCoverage() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city()
        store.save([place])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        for (i, x) in [-400.0, -350, -300, -250, -200].enumerated() {
            visit(model, in: place, x: x, seconds: Double(i) * 40)
        }
        let before = try #require(model.activeWalk)
        #expect(!model.autoWalkPending)
        var still = true
        model.tracker.isStill = { still }
        model.tracker.motionChanged()
        #expect(model.tracker.watch == .light)
        #expect(model.activeWalk?.id == before.id)
        still = false
        model.tracker.motionChanged()
        #expect(model.tracker.watch == .live)
        visit(model, in: place, x: -150, seconds: 220)
        visit(model, in: place, x: -100, seconds: 260)
        #expect(model.activeWalk?.id == before.id)
        #expect(try #require(model.activeWalk).distance > before.distance + 90)
        #expect(model.walks.isEmpty)
    }

    @Test func onlyTheVisibleMapAsksForForegroundAccuracy() {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        model.foreground(true)
        #expect(!model.tracker.isOnScreen())
        model.mapVisibility(true)
        #expect(model.tracker.isOnScreen())
        model.mapVisibility(false)
        #expect(!model.tracker.isOnScreen())
        model.mapVisibility(true)
        model.foreground(false)
        #expect(!model.tracker.isOnScreen())
    }

    @Test func fixesAfterTheGapNeverJoinAWalkStillWaitingToFinish() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city()
        store.save([place])
        let start = Date.now.addingTimeInterval(-300)
        let points = [-200.0, 0.0].enumerated().map { index, x in
            let c = coordinate(in: place, x: x)
            return TrackPoint(lat: c.lat, lon: c.lon, time: start.timeIntervalSince1970 + Double(index) * 80, accuracy: 5, speed: 1)
        }
        let old = Walk(startedAt: start, points: points, distance: 200, automatic: true)
        store.save(old)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        // History is still being prepared, so finishing the old walk has to wait.
        #expect(!model.historyReady)
        #expect(model.activeWalk?.id == old.id)
        for (i, x) in [100.0, 150, 200].enumerated() { visit(model, in: place, x: x, seconds: 400 + Double(i) * 40) }
        #expect(model.activeWalk?.points.count == 2)
        await model.waitForHistory()
        for _ in 0..<50 where model.activeWalk != nil { await Task.yield() }
        #expect(model.activeWalk == nil)
        for (i, x) in [300.0, 350, 400].enumerated() { visit(model, in: place, x: x, seconds: 600 + Double(i) * 40) }
        let next = try #require(model.activeWalk)
        #expect(next.id != old.id)
        #expect(next.points.allSatisfy { $0.time > Date.now.timeIntervalSince1970 + 500 })
        // The other deferred finishes were for the old walk, so this one carries on.
        for _ in 0..<20 { await Task.yield() }
        #expect(model.activeWalk?.id == next.id)
    }

    @Test func deletingTheSelectedPlaceKeepsWalksAndPicksAnother() async throws {
        let store = store()
        defer { store.wipe() }
        let keep = city("Keep"), gone = city("Gone")
        store.save([keep, gone])
        let date = Date.now.addingTimeInterval(-86400)
        let c = coordinate(in: gone, x: 0)
        store.save(Walk(startedAt: date, endedAt: date.addingTimeInterval(600),
                        points: [TrackPoint(lat: c.lat, lon: c.lon, time: date.timeIntervalSince1970, accuracy: 5, speed: 1)]))
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var deleted: [UUID] = []
        model.placesDeleted = { deleted += $0 }
        model.select(gone.id)
        let flights = model.flyToSelected
        model.deleteCity(gone.id)
        #expect(deleted == [gone.id])
        #expect(model.cities.map(\.id) == [keep.id])
        #expect(model.selectedCityID == keep.id)
        #expect(model.flyToSelected == flights + 1)
        #expect(model.walks.count == 1)
        store.flush()
        #expect(store.loadCities().map(\.id) == [keep.id])
        #expect(store.loadWalks().count == 1)
    }

    @Test func beforeTheFirstUnlockNothingIsLoadedOrSavedOver() async throws {
        let store = store()
        defer { store.wipe() }
        let place = city(visited: 3)
        store.save([place])
        store.flush()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, waitForUnlock: true)
        #expect(model.locked)
        #expect(model.cities.isEmpty)
        // A walk, location events and a trip to the background before the unlock.
        model.startWalk()
        for (i, x) in [-400.0, -350, -300, -250, -200].enumerated() { visit(model, in: place, x: x, seconds: Double(i) * 40) }
        #expect(model.activeWalk == nil)
        model.saveNow(waiting: true)
        #expect(store.loadCities().map(\.id) == [place.id])
        #expect(store.loadWalks().isEmpty)
        model.loadSaved()
        #expect(!model.locked)
        #expect(model.cities.map(\.id) == [place.id])
        #expect(model.cities.first?.visited.count == 3)
        await model.waitForHistory()
        #expect(model.historyReady)
    }
}
