import Foundation

nonisolated enum CityBuilder {
    /// Square metres. Anything bigger is years of walking, so we suggest a suburb instead.
    static let maxArea = 400_000_000.0

    /// Lays a hex grid over the place, keeps the tiles with a street or path through
    /// them, then replays every past walk so the new city starts with what you've done.
    @concurrent
    static func build(
        from place: PlaceResult,
        walks: [Walk],
        client: ConvexClient? = nil,
        status: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> City {
        if let osmId = place.osmId, let client {
            await status("Getting \(place.name) ready…")
            do {
                let cached = try await CachedPlaceData.fetch(osmId: osmId, client: client)
                var cachedPlace = place
                cachedPlace.boundary = cached.boundary
                await status("Laying out the tiles…")
                return build(from: cachedPlace, ways: cached.ways, walks: walks, streetsVersion: cached.streetsVersion)
            } catch {
                // The local-first path still works with older deployments or an
                // unavailable cache. Cancellation should stop the add altogether.
                try Task.checkCancellation()
            }
        }
        await status("Finding the streets and paths…")
        let b = place.boundary.bounds
        let ways = try await OSMClient.walkableWays(south: b.south, west: b.west, north: b.north, east: b.east, session: client?.session ?? .shared)
        await status("Laying out the tiles…")
        // Straight from Overpass, with every tag, so WalkableRule has already filtered them.
        return build(from: place, ways: ways, walks: walks, streetsVersion: WalkableRule.version)
    }

    /// Both network paths use the same tile selection, road hints and walk replay.
    static func build(from place: PlaceResult, ways: [OSMWay], walks: [Walk], streetsVersion: Int? = nil) -> City {
        let grid = HexGrid.world
        let shape = BoundaryShape(place.boundary, projection: grid.projection)
        var city = City(
            name: place.name, detail: place.detail, osmId: place.osmId, boundary: place.boundary,
            tiles: streetTiles(from: ways, inside: City.hexes(inside: shape, grid: grid)), visited: [], roads: roadLines(from: ways),
            streetsVersion: streetsVersion
        )
        for walk in walks {
            _ = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
        }
        return city
    }

    /// The tiles in the place with a walkable street or path through them.
    static func streetTiles(from ways: [OSMWay], inside: Set<Hex>) -> Set<Hex> {
        let grid = HexGrid.world
        var tiles = Set<Hex>()
        // A driveway leads onto someone's property, so it doesn't make a tile count.
        for way in ways where way.tags["service"] != "driveway" {
            for point in samples(along: way.points) {
                let h = grid.hex(containing: point)
                if inside.contains(h) { tiles.insert(h) }
            }
        }
        // Somewhere with no mapped paths at all: fall back to every tile.
        return tiles.isEmpty ? inside : tiles
    }

    struct Replay: Sendable {
        var cities: [City]
        var walks: [Walk]
        var secrets: [String: Date]
    }

    /// Rebuild derived records in walk order, using exactly the live coverage filters
    /// and City.visit path. Purchases, spyglasses and short-outing credits stay gone.
    static func replay(_ walks: [Walk], through cities: [City]) -> Replay {
        var result = Replay(cities: cities, walks: [], secrets: [:])
        let shapes = cities.map { $0.shape() }
        for var walk in walks.sorted(by: {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }) {
            walk.resetGridCoverage()
            var fresh: [String: Set<Hex>] = [:]
            var added: [String: Set<Hex>] = [:]
            let samples = CoverageTracer.samples(for: walk.points)
            for i in result.cities.indices {
                let old = result.cities[i].tiles
                let uncovered = result.cities[i].visit(samples, within: shapes[i])
                fresh[result.cities[i].id.uuidString] = uncovered
                added[result.cities[i].id.uuidString] = uncovered.subtracting(old)
                for (id, hex) in result.cities[i].stickers ?? [:] where uncovered.contains(hex) && result.secrets[id] == nil {
                    result.secrets[id] = walk.endedAt ?? walk.startedAt
                }
            }
            walk.newTileHexesByPlace = fresh
            walk.addedTilesByPlace = added
            walk.newTilesByPlace = fresh.mapValues(\.count)
            walk.newTiles = fresh.values.reduce(0) { $0 + $1.count }
            walk.distance = CoverageTracer.distance(for: walk.points)
            result.walks.append(walk)
        }
        return result
    }

    /// The streets and paths worth hinting at under the clouds. Everything walkable
    /// still counts for tiles; this just drops the clutter (sidewalks drawn alongside
    /// roads, crossings, driveways and car park aisles).
    static func roadLines(from ways: [OSMWay]) -> [RoadLine] {
        let pathTypes: Set = ["footway", "path", "cycleway", "steps", "pedestrian", "track", "bridleway"]
        return ways.compactMap { way in
            if ["sidewalk", "crossing", "traffic_island"].contains(way.tags["footway"] ?? "") { return nil }
            if ["driveway", "parking_aisle", "drive-through"].contains(way.tags["service"] ?? "") { return nil }
            guard way.points.count > 1 else { return nil }
            let kind: RoadLine.Kind = pathTypes.contains(way.tags["highway"] ?? "") ? .path : .road
            return RoadLine(kind: kind, points: way.points)
        }
    }

    /// Points every few metres along a line, so short tiles between nodes aren't skipped.
    static func samples(along line: [Coordinate]) -> [Coordinate] {
        guard var prev = line.first else { return [] }
        var out = [prev]
        for next in line.dropFirst() {
            let n = max(1, Int((prev.distance(to: next) / CoverageTracer.spacing).rounded(.up)))
            for i in 1...n {
                out.append(prev.lerp(to: next, Double(i) / Double(n)))
            }
            prev = next
        }
        return out
    }
}
