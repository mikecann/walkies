import Foundation
import simd

nonisolated struct GeoPolygon: Codable, Hashable, Sendable {
    var outer: [Coordinate]
    var holes: [[Coordinate]]
}

/// A place's outline from OpenStreetMap. Can be several polygons (islands etc).
nonisolated struct Boundary: Codable, Hashable, Sendable {
    var polygons: [GeoPolygon]

    var bounds: (south: Double, west: Double, north: Double, east: Double) {
        let all = polygons.flatMap(\.outer)
        return (
            all.map(\.lat).min() ?? 0, all.map(\.lon).min() ?? 0,
            all.map(\.lat).max() ?? 0, all.map(\.lon).max() ?? 0
        )
    }

    var centre: Coordinate {
        let b = bounds
        return Coordinate(lat: (b.south + b.north) / 2, lon: (b.west + b.east) / 2)
    }

    /// Somewhere inside the place to put its name: the middle of its biggest piece,
    /// or for a crescent or L shape whose middle is outside it, the nearest spot
    /// that's inside.
    var labelPoint: Coordinate {
        let projection = LocalProjection(origin: centre)
        let shape = BoundaryShape(self, projection: projection)
        guard let biggest = polygons.max(by: { $0.outer.count < $1.outer.count }) else { return centre }
        let ring = biggest.outer.map(projection.project)
        var area = 0.0, sum = SIMD2<Double>(0, 0)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let cross = a.x * b.y - b.x * a.y
            area += cross
            sum += (a + b) * cross
        }
        let middle = abs(area) > 1e-9 ? sum / (3 * area) : (shape.lo + shape.hi) / 2
        if shape.contains(middle) { return projection.unproject(middle) }
        var best: SIMD2<Double>?
        for i in 0...20 {
            for j in 0...20 {
                let p = shape.lo + (shape.hi - shape.lo) * SIMD2(Double(i) / 20, Double(j) / 20)
                guard shape.contains(p) else { continue }
                if best == nil || simd_distance(p, middle) < simd_distance(best!, middle) { best = p }
            }
        }
        return projection.unproject(best ?? middle)
    }
}

/// A boundary projected into a city's local metres, for fast point-in-polygon tests.
nonisolated struct BoundaryShape: Sendable {
    private struct Part: Sendable {
        var outer: [SIMD2<Double>]
        var holes: [[SIMD2<Double>]]
    }

    private let parts: [Part]
    let lo: SIMD2<Double>
    let hi: SIMD2<Double>

    init(_ boundary: Boundary, projection: LocalProjection) {
        parts = boundary.polygons.map { poly in
            Part(outer: poly.outer.map(projection.project), holes: poly.holes.map { $0.map(projection.project) })
        }
        let all = parts.flatMap(\.outer)
        lo = SIMD2(all.map(\.x).min() ?? 0, all.map(\.y).min() ?? 0)
        hi = SIMD2(all.map(\.x).max() ?? 0, all.map(\.y).max() ?? 0)
    }

    func contains(_ p: SIMD2<Double>) -> Bool {
        guard p.x >= lo.x, p.x <= hi.x, p.y >= lo.y, p.y <= hi.y else { return false }
        return parts.contains { part in
            Self.ring(part.outer, contains: p) && !part.holes.contains { Self.ring($0, contains: p) }
        }
    }

    /// Area in square metres.
    var area: Double {
        parts.reduce(0) { total, part in
            total + abs(Self.signedArea(part.outer)) - part.holes.reduce(0) { $0 + abs(Self.signedArea($1)) }
        }
    }

    private static func ring(_ ring: [SIMD2<Double>], contains p: SIMD2<Double>) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count > 2 else { return 0 }
        var sum = 0.0
        var j = ring.count - 1
        for i in ring.indices {
            sum += (ring[j].x * ring[i].y) - (ring[i].x * ring[j].y)
            j = i
        }
        return sum / 2
    }
}
