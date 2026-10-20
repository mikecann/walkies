import Foundation
import MapKit
import Testing
@testable import Walkies

struct CloudTests {
    let start = Coordinate(lat: -33.638, lon: 115.386)

    func hex(q: Int32, r: Int32) -> Hex {
        let base = HexGrid.world.hex(containing: start)
        return Hex(q: base.q + q, r: base.r + r)
    }

    func city(tiles: Set<Hex>, visited: Set<Hex>, roads: [RoadLine]? = nil) -> City {
        let projection = HexGrid.world.projection
        let base = HexGrid.world.centre(of: hex(q: 0, r: 0))
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map { projection.unproject(base + $0) }, holes: [])])
        return City(
            name: "Test", detail: "", boundary: boundary,
            tiles: tiles, visited: visited, roads: roads
        )
    }

    @Test func wholeSuburbStartsUnderCloud() {
        let test = city(tiles: [hex(q: 0, r: 0), hex(q: 1, r: 0)], visited: [])
        let cover = test.cloudCover()
        #expect(cover.clear.isEmpty)
        #expect(cover.clouded == City.hexes(inside: test.shape(), grid: test.grid))
        #expect(CloudField(city: test).puffs.count == cover.clouded.count)
    }

    @Test func walkingBesideBushClearsTheWholePatch() {
        // Two lone street tiles at opposite sides of the suburb; everything else is bush.
        let west = hex(q: -3, r: 0), east = hex(q: 4, r: 0)
        let test = city(tiles: [west, east], visited: [west])
        let cover = test.cloudCover()

        #expect(cover.clear.contains(west))
        #expect(cover.clear.contains(hex(q: -4, r: 1)))  // bush next to the walked street
        #expect(cover.clear.contains(hex(q: 4, r: 1)))   // and all the bush it joins up with
        #expect(cover.clouded == [east])
        #expect(cover.blocked.isEmpty)
        // Clearing bush doesn't change the score: only street tiles count.
        #expect(test.progress == 0.5)
    }

    @Test func bushWalledInByUnwalkedStreetsStaysClouded() {
        // A pocket of bush with a ring of streets round it, and a walked street outside.
        let pocket = hex(q: 0, r: 0)
        let ring = Set(pocket.neighbours)
        let walked = hex(q: -3, r: 0)
        let cover = city(tiles: ring.union([walked]), visited: [walked]).cloudCover()

        #expect(cover.blocked == [pocket])
        #expect(cover.clouded.contains(pocket))
        #expect(cover.clear.contains(hex(q: 3, r: 0)))  // the bush outside the ring
    }

    @Test func tiesAlwaysGoTheSameWay() {
        // Built in different orders, so the sets are likely to iterate differently.
        let a: Set = [hex(q: -2, r: 0), hex(q: 2, r: 0)]
        var b = Set<Hex>(minimumCapacity: 64)
        b.insert(hex(q: 2, r: 0))
        b.insert(hex(q: -2, r: 0))
        let first = city(tiles: a, visited: [hex(q: -2, r: 0)]).cloudCover().clear
        let second = city(tiles: b, visited: [hex(q: -2, r: 0)]).cloudCover().clear
        #expect(first == second)
    }

    @Test func cloudsAreTheSameEveryTime() {
        let tiles: Set = [hex(q: 0, r: 0), hex(q: 3, r: -2), hex(q: -4, r: 1)]
        let a = CloudField(city: city(tiles: tiles, visited: []))
        let b = CloudField(city: city(tiles: tiles, visited: []))
        let rects = { (field: CloudField) in field.puffs.map { [$0.centre.x, $0.centre.y, $0.radius, $0.phase] } }
        #expect(rects(a) == rects(b))
        #expect(a.puffs.map(\.variant) == b.puffs.map(\.variant))
    }

    @Test func roadLinesDropClutter() {
        let line = [Coordinate(lat: -33.63, lon: 115.38), Coordinate(lat: -33.631, lon: 115.381)]
        let ways = [
            OSMWay(tags: ["highway": "residential"], points: line),
            OSMWay(tags: ["highway": "footway"], points: line),
            OSMWay(tags: ["highway": "footway", "footway": "sidewalk"], points: line),
            OSMWay(tags: ["highway": "footway", "footway": "crossing"], points: line),
            OSMWay(tags: ["highway": "service", "service": "driveway"], points: line),
            OSMWay(tags: ["highway": "service"], points: line),
            OSMWay(tags: ["highway": "path"], points: [line[0]]),
        ]
        let lines = CityBuilder.roadLines(from: ways)
        #expect(lines.map(\.kind) == [.road, .path, .road])
    }

    @Test func citiesSavedBeforeRoadsStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(city(tiles: [hex(q: 0, r: 0)], visited: []))) as! [String: Any]
        json["roads"] = nil
        let old = try JSONDecoder().decode(City.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.roads == nil)
        #expect(old.tiles == [hex(q: 0, r: 0)])
    }
}
