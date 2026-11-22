import Foundation
import Testing
@testable import Walkies

@MainActor
@Suite(.serialized)
struct ExplicitEndTests {
    @Test(arguments: [100.0, 200.0])
    func pressingEndKeepsEvenAShortAutomaticWalk(metres: Double) async throws {
        let root = URL.temporaryDirectory.appending(path: "WalkiesExplicitEnd-\(UUID())")
        let store = Store(root: root)
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: true)
        await model.waitForHistory()
        let place = ModelFixesTests().city(origin: Coordinate(lat: 0, lon: 0))
        model.add(place)
        let start = Date.now.timeIntervalSince1970
        for (i, x) in stride(from: 0.0, through: metres, by: 50).enumerated() {
            model.recordAlwaysOnForTesting(TrackPoint(lat: x / 111195, lon: 0, time: start + Double(i) * 40, accuracy: 5, speed: 1))
        }
        let old = try #require(model.activeWalk)
        model.endAutoWalk()
        #expect(model.activeWalk == nil)
        #expect(model.walks.first?.id == old.id)
        #expect(store.loadWalks().first?.points == old.points)
        #expect(!model.cities[0].visited.isEmpty)
        #expect(store.loadCities()[0].visited == model.cities[0].visited)
    }
}
