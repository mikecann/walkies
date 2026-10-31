import Foundation
import MapKit
import Testing
@testable import Walkies

/// The world's clouds outside your places, and asking the server about the suburbs around you.
struct WorldCloudsTests {
    let grid = HexGrid.world
    let origin = Coordinate(lat: -33.65, lon: 115.35)

    func spot(x: Double, y: Double = 0) -> Coordinate {
        grid.projection.unproject(grid.projection.project(origin) + SIMD2(x, y))
    }

    /// A square `half` metres either side of `x` metres east of `origin`.
    func boundary(x: Double, half: Double = 1000) -> Boundary {
        let ring = [SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half), SIMD2(-half, -half)]
            .map { spot(x: x + $0.x, y: $0.y) }
        return Boundary(polygons: [GeoPolygon(outer: ring, holes: [])])
    }

    func place(_ osmId: Int, x: Double, half: Double = 1000) -> PlaceResult {
        PlaceResult(id: osmId, name: "P\(osmId)", detail: "Tests", kind: "suburb", boundary: boundary(x: x, half: half), area: 4 * half * half, osmId: osmId)
    }

    func city(_ osmId: Int, x: Double) -> City {
        var city = City(name: "C\(osmId)", detail: "", boundary: boundary(x: x), tiles: [], visited: [])
        city.osmId = osmId
        return city
    }

    @Test func puffsGetFurtherApartAsYouZoomOutSoATileNeverHasTooMany() {
        let (closest, spacing) = WorldCloudLayout.spacing(zoomScale: 10)
        #expect(closest == 0)
        #expect(spacing == WorldCloudLayout.closest)
        // A map tile is 256 points across whatever the zoom, from street level to the whole world.
        for zoomScale in [1.0, 0.1, 0.01, 1e-3, 1e-4, 1e-5, 1e-6] {
            let (_, spacing) = WorldCloudLayout.spacing(zoomScale: zoomScale)
            #expect(spacing * zoomScale >= WorldCloudLayout.screenSpacing || spacing >= MKMapSize.world.width)
            let side = 256 / zoomScale
            let tile = MKMapRect(x: MKMapSize.world.width / 2, y: MKMapSize.world.height / 2, width: side, height: side)
            #expect(WorldCloudLayout.puffs(in: tile, zoomScale: zoomScale).count < 400)
        }
    }

    @Test func neighbouringTilesAgreeOnThePuffsTheyShare() {
        let zoomScale = 0.05
        let side = 256 / zoomScale
        let left = MKMapRect(x: 220_000_000, y: 160_000_000, width: side, height: side)
        let right = MKMapRect(x: left.maxX, y: left.minY, width: side, height: side)
        let edge = MKMapRect(x: left.maxX - 1, y: left.minY, width: 2, height: side)
        let shared = { (rect: MKMapRect) in
            WorldCloudLayout.puffs(in: rect, zoomScale: zoomScale).filter { $0.box.intersects(edge) }.map { [$0.centre.x, $0.centre.y, $0.box.width, Double($0.variant)] }
        }
        let fromLeft = shared(left)
        let fromRight = shared(right)
        #expect(!fromLeft.isEmpty)
        #expect(fromLeft == fromRight)
        // North first, so the ones further south sit in front.
        let all = WorldCloudLayout.puffs(in: left, zoomScale: zoomScale)
        #expect(all.map(\.centre.y) == all.map(\.centre.y).sorted())
    }

    @Test func walkingAnywhereClearsTheWorldsClouds() {
        // A walk east along a street nowhere near any place, a fix every 8 m.
        let points = (0..<40).map { i in
            let c = spot(x: 50_000 + Double(i) * 8)
            return TrackPoint(lat: c.lat, lon: c.lon, time: 1_800_000_000 + Double(i) * 6, accuracy: 5, speed: 1.3)
        }
        let walk = Walk(startedAt: .now, points: points)
        let tiles = CoverageTracer.worldTiles(of: [walk])
        #expect(tiles.contains(grid.hex(containing: spot(x: 50_100))))
        #expect(tiles.contains(grid.hex(containing: spot(x: 50_250))))
        #expect(!tiles.contains(grid.hex(containing: spot(x: 51_000))))
        // And the holes are found from the squares they're kept in.
        let buckets = WorldCloudLayout.buckets(tiles)
        let centre = WorldCloudLayout.centre(of: grid.hex(containing: spot(x: 50_100)))
        let near = MKMapRect(x: centre.x - 10, y: centre.y - 10, width: 20, height: 20)
        #expect(WorldCloudLayout.walked(near: near, in: buckets).contains { $0.x == centre.x && $0.y == centre.y })
        let far = WorldCloudLayout.centre(of: grid.hex(containing: spot(x: 80_000)))
        #expect(WorldCloudLayout.walked(near: MKMapRect(x: far.x, y: far.y, width: 20, height: 20), in: buckets).isEmpty)
    }

    @Test func theSuburbYoureInComesFirstThenTheOnesNextToIt() {
        let here = city(1, x: 0)
        // Touching to the east, 400 m off to the west, and 5 km away.
        let nearby = [place(2, x: 2000), place(3, x: -2400), place(4, x: 8000)]
        #expect(AroundYou.suburbs(at: spot(x: 100), places: [here], nearby: nearby, bundled: []) == [1, 2, 3])
        // Not in one of your places yet: the suburb from the neighbours list instead.
        #expect(AroundYou.suburbs(at: spot(x: 8000), places: [here], nearby: nearby, bundled: []) == [4])
        // Bundled ones already have their secrets.
        #expect(AroundYou.suburbs(at: spot(x: 100), places: [here], nearby: nearby, bundled: [1, 3]) == [2])
        // In none we know of (out at sea, say), there's nothing to ask about.
        #expect(AroundYou.suburbs(at: spot(x: 0, y: 50_000), places: [here], nearby: nearby, bundled: []).isEmpty)
    }

    @Test func theSameSuburbsArentAskedAboutAgainForHalfAnHour() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AroundYou.due([1, 2], last: nil, now: now))
        #expect(!AroundYou.due([], last: nil, now: now))
        let last = (ids: [2, 1], at: now)
        #expect(!AroundYou.due([1, 2], last: last, now: now.addingTimeInterval(60)))
        #expect(AroundYou.due([1, 3], last: last, now: now.addingTimeInterval(60)))
        #expect(AroundYou.due([1, 2], last: last, now: now.addingTimeInterval(AroundYou.again)))
    }

    @MainActor @Test func theAppAsksTheServerAboutTheSuburbsAroundYou() async throws {
        let store = Store(root: URL.temporaryDirectory.appending(path: "WalkiesWorld-\(UUID())"))
        store.save([city(9_000_001, x: 0)])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var asked: [[Int]] = []
        model.askToPrepare = { asked.append($0) }
        model.prepareAround(spot(x: 100))
        try await Task.sleep(for: .milliseconds(100))
        model.prepareAround(spot(x: 150))
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked == [[9_000_001]])
    }
}
