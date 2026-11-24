import Foundation
import Testing
@testable import Walkies

/// docs/walk-lifecycle.md: a walk closes the moment it ends, and saved places only ever
/// hold finished walks. These cover the moments around closing that older versions got
/// wrong: steps that come back late or never, the app stopping between writes, and two
/// outings over the same tiles.
@MainActor
@Suite(.serialized)
struct SealedWalkTests {
    let start = 100_000.0

    func point(_ metres: Double, _ elapsed: Double) -> TrackPoint {
        TrackPoint(lat: metres / LocalProjection.earthRadius * 180 / .pi, lon: 0,
                   time: start + elapsed, accuracy: 5, speed: 1)
    }

    func store(_ name: String) -> (Store, URL) {
        let root = URL.temporaryDirectory.appending(path: "Walkies\(name)-\(UUID())")
        return (Store(root: root), root)
    }

    /// A step count that only comes back when the test says so.
    final class HeldSteps {
        var continuation: CheckedContinuation<Int?, Never>?
        var asked = 0
        func count(_ start: Date, _ end: Date) async -> Int? {
            asked += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        func reply(_ count: Int?) { continuation?.resume(returning: count); continuation = nil }
        func waitForQuestion() async { for _ in 0..<1000 where continuation == nil { await Task.yield() } }
    }

    final class Clock: @unchecked Sendable {
        var time: Double
        init(_ time: Double) { self.time = time }
        func now() -> Date { Date(timeIntervalSince1970: time) }
    }

    /// Walks always on through `xs` (metres east), one fix every 40 s from `from`.
    func walk(_ model: AppModel, clock: Clock, _ xs: [Double], from: Double) {
        for (i, x) in xs.enumerated() {
            let fix = point(x, from + Double(i) * 40)
            clock.time = fix.time
            model.recordAlwaysOnForTesting(fix)
        }
    }

    @Test func theStageMovesMatchTheSharedTable() throws {
        let url = ProcessInfo.processInfo.environment["WALKIES_STAGE_TABLE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "shared/fixtures/walk-stages.json")
        let shared = try Data(contentsOf: url)
        struct Table: Decodable {
            struct Move: Decodable { let from: String; let event: String; let to: String? }
            let stages: [String]
            let events: [String]
            let moves: [Move]
        }
        let table = try JSONDecoder().decode(Table.self, from: shared)
        #expect(Set(table.stages) == Set(WalkStage.allCases.map(\.rawValue)))
        #expect(Set(table.events) == Set(WalkStage.Event.allCases.map(\.rawValue)))
        var allowed: [String: String?] = [:]
        for move in table.moves { allowed["\(move.from) \(move.event)"] = .some(move.to) }
        for stage in WalkStage.allCases {
            for event in WalkStage.Event.allCases {
                let key = "\(stage.rawValue) \(event.rawValue)"
                #expect(stage.allows(event) == (allowed[key] != nil), "\(key)")
                if let to = allowed[key] { #expect(stage.after(event)?.rawValue == to, "\(key)") }
            }
        }
    }

    @Test func aWalkClosesStraightAwayAndItsStepsFillInLater() async throws {
        let (store, _) = store("SealedSteps")
        defer { store.wipe() }
        store.save([ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))])
        let steps = HeldSteps()
        let clock = Clock(start)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, stepQuery: steps.count, now: clock.now)
        model.countSteps = true
        await model.waitForHistory()
        var changed: [UUID] = []
        model.walksChanged = { changed += $0 }
        walk(model, clock: clock, (0...10).map { Double($0) * 50 }, from: 0)
        let first = try #require(model.activeWalk)
        // Ten minutes later you set off again from the same spot.
        walk(model, clock: clock, (0...4).map { 500 + Double($0) * 50 }, from: 1100)
        let closed = try #require(model.walks.first { $0.id == first.id })
        #expect(closed.stage == .done && closed.endedAt != nil && closed.steps == nil && closed.stepsPending == true)
        #expect(model.activeWalk?.id != first.id)
        #expect(store.loadCities()[0].visited == model.walks[0].newTileHexesByPlace?.values.first)
        await steps.waitForQuestion()
        steps.reply(1234)
        for _ in 0..<1000 where model.walks.first?.steps == nil { await Task.yield() }
        #expect(model.walks.first?.steps == 1234 && model.walks.first?.stepsPending == nil)
        #expect(store.loadWalks().first { $0.id == first.id }?.steps == 1234)
        #expect(changed == [first.id])
    }

    @Test func stepsStillOutstandingWhenTheAppStopsAreAskedForAgain() async throws {
        let (store, root) = store("SealedStepsRelaunch")
        defer { store.wipe() }
        let steps = HeldSteps()
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false, stepQuery: steps.count)
        model.countSteps = true
        await model.waitForHistory()
        model.startWalk()
        let id = try #require(model.activeWalk?.id)
        model.endWalk()
        await steps.waitForQuestion()
        // The app stops before the motion chip answers.
        let relaunched = AppModel(store: Store(root: root), servicesEnabled: false, alwaysOn: false,
                                  stepQuery: { _, _ in 42 })
        await relaunched.waitForHistory()
        for _ in 0..<1000 where relaunched.walks.first?.steps == nil { await Task.yield() }
        #expect(relaunched.walks.map(\.id) == [id])
        #expect(relaunched.walks.first?.steps == 42 && relaunched.walks.first?.stepsPending == nil)
        steps.reply(7)
    }

    @Test(arguments: [false, true])
    func aWalkSealedJustBeforeTheAppStoppedReachesTheSavedPlacesOnce(placesSaved: Bool) async throws {
        let (store, _) = store("SealedCommit")
        defer { store.wipe() }
        var place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        let points = (0...8).map { point(Double($0) * 50, Double($0) * 40) }
        var preview = place
        let fresh = preview.visit(CoverageTracer.samples(for: points), within: preview.shape())
        #expect(!fresh.isEmpty)
        if placesSaved { place = preview }
        store.save([place])
        store.flush()
        let sealed = Walk(startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: start + 320),
                          points: points, distance: CoverageTracer.distance(for: points), newTiles: fresh.count,
                          newTilesByPlace: [place.id.uuidString: fresh.count], newTileHexesByPlace: [place.id.uuidString: fresh],
                          addedTilesByPlace: [:], automatic: true, stage: .sealed)
        store.save(sealed)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.cities[0].visited == fresh)
        #expect(store.loadCities()[0].visited == fresh)
        #expect(model.walks.map(\.id) == [sealed.id])
        #expect(store.loadWalks().first?.stage == .done)
        #expect(model.questTileCounts[sealed.id]?[place.id] == fresh.count)
    }

    @Test(arguments: [false, true])
    func aShortOutingSealedJustBeforeTheAppStoppedKeepsOneTileCredit(placesSaved: Bool) async throws {
        let (store, _) = store("SealedShort")
        defer { store.wipe() }
        var place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        let points = (0...4).map { point(Double($0) * 40, Double($0) * 40) }
        var preview = place
        let fresh = preview.visit(CoverageTracer.samples(for: points), within: preview.shape())
        var short = Walk(startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: start + 160),
                         points: points, newTileHexesByPlace: [place.id.uuidString: fresh], addedTilesByPlace: [:],
                         automatic: true, stage: .sealed)
        short.short = true
        if placesSaved {
            place = preview
            place.tileCredits = [City.TileCredit(id: short.id, at: short.startedAt, hexes: fresh)]
        }
        store.save([place])
        store.flush()
        store.save(short)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        #expect(model.walks.isEmpty)
        #expect(store.loadWalks().isEmpty)
        #expect(model.cities[0].tileCredits?.filter { $0.id == short.id }.count == 1)
        #expect(store.loadCities()[0].tileCredits?.filter { $0.id == short.id }.count == 1)
        #expect(store.loadCities()[0].visited == fresh)
    }

    @Test func savedPlacesNeverHoldTheOpenWalksTiles() async throws {
        let (store, _) = store("SealedOpen")
        defer { store.wipe() }
        store.save([ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))])
        let clock = Clock(start)
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: clock.now)
        await model.waitForHistory()
        walk(model, clock: clock, (0...10).map { Double($0) * 50 }, from: 0)
        #expect(!model.autoWalkPending && !model.cities[0].visited.isEmpty)
        model.saveNow(waiting: true)
        #expect(store.loadCities()[0].visited.isEmpty)
        #expect(store.loadCities()[0].tiles == ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0)).tiles)
    }

    @Test func theEarlierOfTwoOutingsOverTheSameTilesGetsTheCredit() async throws {
        let (store, root) = store("SealedOrder")
        defer { store.wipe() }
        store.save([ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))])
        let clock = Clock(start)
        var model = AppModel(store: store, servicesEnabled: false, alwaysOn: true, now: clock.now)
        await model.waitForHistory()
        let route = (0...10).map { Double($0) * 50 }
        walk(model, clock: clock, route, from: 0)
        let first = try #require(model.activeWalk?.id)
        // The same route again after a break, with the app stopped partway through.
        walk(model, clock: clock, Array(route.prefix(6)), from: 1100)
        let second = try #require(model.activeWalk?.id)
        #expect(second != first)
        model.saveNow(waiting: true)
        clock.time += 30
        model = AppModel(store: Store(root: root), servicesEnabled: false, alwaysOn: true, now: clock.now)
        await model.waitForHistory()
        #expect(model.activeWalk?.id == second)
        walk(model, clock: clock, Array(route.dropFirst(6)), from: clock.time - start + 40)
        clock.time += 700
        model.finishStaleAutoWalk()
        let credit = Dictionary(uniqueKeysWithValues: model.walks.map { ($0.id, $0.newTiles) })
        #expect(credit[first]! > 0)
        #expect(credit[second] == 0)
        #expect(store.loadCities()[0].visited == model.walks.first { $0.id == first }?.newTileHexesByPlace?.values.first)
    }
}
