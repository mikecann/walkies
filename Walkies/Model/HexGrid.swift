import Foundation

/// A tile, in axial coordinates on a pointy-top hex grid.
nonisolated struct Hex: Hashable, Sendable {
    var q: Int32
    var r: Int32
}

nonisolated extension Hex {
    var neighbours: [Hex] {
        [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)].map { Hex(q: q + Int32($0.0), r: r + Int32($0.1)) }
    }
}

// Stored as [q, r] to keep the save files small.
nonisolated extension Hex: Codable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        q = try c.decode(Int32.self)
        r = try c.decode(Int32.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(q)
        try c.encode(r)
    }
}

nonisolated struct HexGrid: Hashable, Sendable {
    static let version = 2
    static let world = HexGrid()
    let projection = WorldProjection()
    /// Centre-to-corner distance in projected units, true metres at -33.65°.
    let size = 50.0

    private init() {}

    var tileArea: Double { 3 * 3.0.squareRoot() / 2 * size * size }

    func hex(at p: SIMD2<Double>) -> Hex {
        let q = (3.0.squareRoot() / 3 * p.x - p.y / 3) / size
        let r = (2.0 / 3 * p.y) / size
        return Self.round(q: q, r: r)
    }

    func hex(containing c: Coordinate) -> Hex {
        hex(at: projection.project(c))
    }

    func centre(of h: Hex) -> SIMD2<Double> {
        let q = Double(h.q), r = Double(h.r)
        return SIMD2(size * 3.0.squareRoot() * (q + r / 2), size * 1.5 * r)
    }

    func corners(of h: Hex) -> [Coordinate] {
        let c = centre(of: h)
        return (0..<6).map { i in
            let angle = (60 * Double(i) - 30) * .pi / 180
            return projection.unproject(c + SIMD2(size * cos(angle), size * sin(angle)))
        }
    }

    /// Every hex whose centre falls inside the rectangle, in projected metres.
    func hexes(from lo: SIMD2<Double>, to hi: SIMD2<Double>) -> [Hex] {
        let rowHeight = size * 1.5
        let colWidth = size * 3.0.squareRoot()
        var out: [Hex] = []
        let r0 = Int((lo.y / rowHeight).rounded(.down)) - 1
        let r1 = Int((hi.y / rowHeight).rounded(.up)) + 1
        for r in r0...r1 {
            let shift = Double(r) / 2
            let q0 = Int((lo.x / colWidth - shift).rounded(.down)) - 1
            let q1 = Int((hi.x / colWidth - shift).rounded(.up)) + 1
            for q in q0...q1 {
                let h = Hex(q: Int32(q), r: Int32(r))
                let c = centre(of: h)
                if c.x >= lo.x, c.x <= hi.x, c.y >= lo.y, c.y <= hi.y {
                    out.append(h)
                }
            }
        }
        return out
    }

    static func round(q: Double, r: Double) -> Hex {
        let s = -q - r
        var rq = q.rounded(), rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s)
        if dq > dr, dq > ds {
            rq = -rr - rs
        } else if dr > ds {
            rr = -rq - rs
        }
        return Hex(q: Int32(rq), r: Int32(rr))
    }
}
