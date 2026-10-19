import Foundation
import MapKit
import Testing
@testable import Walkies

struct CloudTests {
    let start = Coordinate(lat: -33.638, lon: 115.386)

    func city(tiles: Set<Hex>, visited: Set<Hex>, roads: [RoadLine]? = nil) -> City {
        let projection = LocalProjection(origin: start)
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)]
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        return City(
            name: "Test", detail: "", grid: HexGrid(projection: projection, size: 50), boundary: boundary,
            tiles: tiles, visited: visited, roads: roads
        )
    }

    @Test func cloudsCoverOnlyUnwalkedTiles() {
        let tiles: Set = [Hex(q: 0, r: 0), Hex(q: 1, r: 0), Hex(q: 0, r: 1), Hex(q: 2, r: -1)]
        let visited: Set = [Hex(q: 1, r: 0)]
        let field = CloudField(city: city(tiles: tiles, visited: visited))
        #expect(field.puffs.count == 3)
        #expect(field.clearings.count == 1)
    }

    @Test func cloudsAreTheSameEveryTime() {
        let tiles: Set = [Hex(q: 0, r: 0), Hex(q: 3, r: -2), Hex(q: -4, r: 1)]
        let a = CloudField(city: city(tiles: tiles, visited: []))
        let b = CloudField(city: city(tiles: tiles, visited: []))
        let rects = { (field: CloudField) in field.puffs.map { [$0.rect.origin.x, $0.rect.origin.y, $0.rect.size.width] } }
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
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(city(tiles: [Hex(q: 0, r: 0)], visited: []))) as! [String: Any]
        json["roads"] = nil
        let old = try JSONDecoder().decode(City.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.roads == nil)
        #expect(old.tiles == [Hex(q: 0, r: 0)])
    }
}
