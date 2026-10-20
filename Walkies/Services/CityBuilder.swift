import Foundation

nonisolated enum CityBuilder {
    /// Centre-to-corner size of a tile in metres, so about 87 m across.
    /// Small enough that walking one street doesn't uncover the next one over.
    static let tileSize = 50.0
    /// Square metres. Anything bigger is years of walking, so we suggest a suburb instead.
    static let maxArea = 400_000_000.0

    /// How far away another place's grid can be and still be shared, so neighbouring
    /// places' tiles line up along their borders.
    static let shareGridWithin = 40_000.0

    /// Lays a hex grid over the place, keeps the tiles with a street or path through
    /// them, then replays every past walk so the new city starts with what you've done.
    /// Uses the same grid as any place you've already got nearby.
    @concurrent
    static func build(
        from place: PlaceResult,
        walks: [Walk],
        near cities: [City] = [],
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
                return build(from: cachedPlace, ways: cached.ways, walks: walks, near: cities)
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
        return build(from: place, ways: ways, walks: walks, near: cities)
    }

    /// Both network paths use the same tile selection, road hints and walk replay.
    static func build(from place: PlaceResult, ways: [OSMWay], walks: [Walk], near cities: [City] = []) -> City {
        let centre = place.boundary.centre
        let neighbour = cities
            .filter { $0.grid.size == tileSize && $0.grid.projection.origin.distance(to: centre) < shareGridWithin }
            .min { $0.grid.projection.origin.distance(to: centre) < $1.grid.projection.origin.distance(to: centre) }
        let grid = neighbour?.grid ?? HexGrid(projection: LocalProjection(origin: centre), size: tileSize)
        let shape = BoundaryShape(place.boundary, projection: grid.projection)
        let inside = City.hexes(inside: shape, grid: grid)

        var tiles = Set<Hex>()
        // A driveway leads onto someone's property, so it doesn't make a tile count.
        for way in ways where way.tags["service"] != "driveway" {
            for point in samples(along: way.points) {
                let h = grid.hex(containing: point)
                if inside.contains(h) { tiles.insert(h) }
            }
        }
        // Somewhere with no mapped paths at all: fall back to every tile.
        if tiles.isEmpty { tiles = inside }

        var city = City(
            name: place.name, detail: place.detail, grid: grid, boundary: place.boundary,
            tiles: tiles, visited: [], roads: roadLines(from: ways)
        )
        for walk in walks {
            _ = city.visit(CoverageTracer.samples(for: walk.points), within: shape)
        }
        return city
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
