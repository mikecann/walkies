import Foundation
import simd
import Testing
@testable import Walkies

struct LoreTests {
    let start = Coordinate(lat: -33.638, lon: 115.386)

    /// A 1 km square suburb where every tile has a street, `east` metres east of the start.
    func city(visited: Set<Hex> = [], east: Double = 0, detail: String = "Busselton") -> City {
        let projection = LocalProjection(origin: start)
        let grid = HexGrid(projection: projection, size: 50)
        let corners = [SIMD2(-500.0, -500.0), SIMD2(500, -500), SIMD2(500, 500), SIMD2(-500, 500)].map { $0 + SIMD2(east, 0) }
        let boundary = Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])])
        let tiles = City.hexes(inside: BoundaryShape(boundary, projection: projection), grid: grid)
        return City(name: "Test", detail: detail, grid: grid, boundary: boundary, tiles: tiles, visited: visited)
    }

    func assign(_ entries: [LoreEntry], to cities: [City]) -> [UUID: [String]] {
        LoreLibrary.assign(entries, to: cities) { city, point in
            city.shape().contains(city.grid.projection.project(point))
        }.mapValues { $0.map(\.id) }
    }

    func entry(_ id: String, at place: SIMD2<Double>? = nil) -> LoreEntry {
        let coordinate = place.map { LocalProjection(origin: start).unproject($0) }
        return LoreEntry(
            id: id, title: id, body: "", category: "history",
            place: coordinate.map { LoreEntry.Place(name: id, lat: $0.lat, lon: $0.lon) },
            sticker: "", sources: []
        )
    }

    @Test func storiesAboutASpotGoUnderIt() {
        let test = city()
        let placed = test.placeStickers([entry("jetty", at: SIMD2(200, -150))])
        let hex = try! #require(placed["jetty"])
        #expect(simd_distance(test.grid.centre(of: hex), SIMD2(200, -150)) < 60)
    }

    @Test func spotsOutsideTheSuburbGetScatteredInstead() {
        let test = city()
        let placed = test.placeStickers([entry("far-away", at: SIMD2(5000, 5000))])
        #expect(placed["far-away"] != nil)
        #expect(test.tiles.contains(placed["far-away"]!))
    }

    @Test func everyStickerGetsItsOwnTileSpreadOut() {
        let test = city()
        let entries = (0..<12).map { entry("story-\($0)") }
        let placed = test.placeStickers(entries)
        #expect(placed.count == 12)
        #expect(Set(placed.values).count == 12)
        // Twelve stickers in a square kilometre shouldn't need to sit right next to each other.
        let centres = placed.values.map { test.grid.centre(of: $0) }
        let closest = centres.enumerated().flatMap { i, a in centres.dropFirst(i + 1).map { simd_distance(a, $0) } }.min()!
        #expect(closest > 120)
    }

    @Test func scatteredStickersAvoidTilesYouveWalked() {
        let walked = city().tiles.filter { $0.q < 0 }
        let test = city(visited: walked)
        let placed = test.placeStickers((0..<8).map { entry("story-\($0)") })
        #expect(placed.values.allSatisfy { !walked.contains($0) })
    }

    @Test func placementIsTheSameEveryTime() {
        let entries = (0..<8).map { entry("story-\($0)") } + [entry("spot", at: SIMD2(-100, 100))]
        #expect(city().placeStickers(entries) == city().placeStickers(entries.reversed()))
    }

    @Test func storiesBelongToThePlaceTheyHappened() {
        let home = city(), nextDoor = city(east: 1000)
        let assigned = assign([entry("here", at: SIMD2(0, 0)), entry("there", at: SIMD2(1000, 0))], to: [home, nextDoor])
        #expect(assigned[home.id] == ["here"])
        #expect(assigned[nextDoor.id] == ["there"])
    }

    @Test func storiesSomewhereYouHaventAddedWaitForIt() {
        let assigned = assign([entry("far-away", at: SIMD2(5000, 5000))], to: [city()])
        #expect(assigned.isEmpty)
    }

    @Test func storiesWithoutASpotGoToYourFirstPlaceInTheArea() {
        let elsewhere = city(east: 3000, detail: "Perth"), home = city(), later = city(east: 1000)
        let assigned = assign([entry("general")], to: [elsewhere, home, later])
        #expect(assigned[home.id] == ["general"])
        #expect(assigned.count == 1)
    }

    @Test func newStickersSkipTilesThatAlreadyHaveOne() {
        let test = city()
        let first = test.placeStickers((0..<6).map { entry("old-\($0)") })
        let second = test.placeStickers((0..<6).map { entry("new-\($0)") }, avoiding: Set(first.values))
        #expect(Set(first.values).isDisjoint(with: second.values))
    }

    @Test func stableHashDoesNotChangeBetweenLaunches() {
        // The published FNV-1a value for "a". If this changes, every saved sticker would move.
        #expect(City.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
    }
}
