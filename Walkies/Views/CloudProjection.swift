import MapKit
import simd

/// Turns map points into screen points. The ground is flat, so wherever the camera
/// is, flat or tilted, one perspective transform (a homography) maps it onto the
/// screen. It's measured each frame from four spots spread across the screen: far
/// enough apart that MapKit's rounding doesn't make the clouds wobble when you're
/// zoomed out.
///
/// A plain value with no hold on the map, so a bake can take a copy to another thread.
nonisolated struct Projection: Sendable {
    /// Ground to screen, h33 = 1. Ground is in map points relative to `origin`, over `unit`.
    private let h: [Double]?
    private let origin: MKMapPoint
    private let unit: Double
    private let width: Double
    /// The map point in the middle of the map, for `centreScale`.
    private let centre: MKMapPoint

    /// Where on screen the four spots are, as fractions of its width and height.
    static let spots = [(0.1, 0.4), (0.9, 0.4), (0.9, 0.95), (0.1, 0.95)]
    /// Lower down, for when the top two are looking at sky.
    private static let lowSpots = [(0.1, 0.7), (0.9, 0.7), (0.9, 0.98), (0.1, 0.98)]

    @MainActor
    init(map: MKMapView) {
        let size = map.bounds.size
        let centre = MKMapPoint(map.centerCoordinate)
        for spots in [Self.spots, Self.lowSpots] {
            let screen = spots.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) }
            let coordinates = screen.map { map.convert($0, toCoordinateFrom: map) }
            guard coordinates.allSatisfy(CLLocationCoordinate2DIsValid) else { continue }
            let measured = Projection(ground: coordinates.map(MKMapPoint.init), screen: screen, width: Double(size.width), centre: centre)
            if measured.isValid {
                self = measured
                return
            }
        }
        self = Projection(ground: [], screen: [], width: Double(size.width), centre: centre)
    }

    /// From four ground points and where they are on a screen `width` points wide.
    init(ground: [MKMapPoint], screen: [CGPoint], width: Double, centre: MKMapPoint) {
        let width = max(1, width)
        let origin = ground.first ?? MKMapPoint(x: 0, y: 0)
        let unit = ground.count == 4 ? max(1, hypot(ground[2].x - origin.x, ground[2].y - origin.y)) : 1
        self.width = width
        self.origin = origin
        self.unit = unit
        self.centre = centre
        guard ground.count == 4, screen.count == 4 else {
            h = nil
            return
        }
        h = Self.solve(
            ground: ground.map { (($0.x - origin.x) / unit, ($0.y - origin.y) / unit) },
            screen: screen.map { (Double($0.x) / width, Double($0.y) / width) }
        )
    }

    var isValid: Bool { h != nil }

    /// How close to the camera's own plane the ground can come before it's treated
    /// as behind the camera. 1 is the ground at the 10%, 40% spot on screen.
    static let near = 0.02

    /// Screen position before dividing by depth (z), which is about 1 everywhere on a
    /// flat map and shrinks towards 0 as the ground nears the camera when tilted.
    /// With no measurement, everything's behind the camera and nothing's drawn.
    private func homogeneous(_ p: MKMapPoint) -> SIMD3<Double> {
        guard let h else { return SIMD3(0, 0, 0) }
        let x = (p.x - origin.x) / unit, y = (p.y - origin.y) / unit
        return SIMD3(h[0] * x + h[1] * y + h[2], h[3] * x + h[4] * y + h[5], h[6] * x + h[7] * y + 1)
    }

    private func screen(_ v: SIMD3<Double>) -> CGPoint {
        let z = max(v.z, Self.near)
        return CGPoint(x: v.x / z * width, y: v.y / z * width)
    }

    func point(_ p: MKMapPoint) -> CGPoint {
        screen(homogeneous(p))
    }

    func isInFront(_ p: MKMapPoint) -> Bool {
        homogeneous(p).z >= Self.near
    }

    /// A closed outline on screen, with any part behind the camera cut off.
    func polygon(_ points: [MKMapPoint]) -> [CGPoint] {
        let v = points.map(homogeneous)
        var out: [CGPoint] = []
        for i in v.indices {
            let previous = v[(i + v.count - 1) % v.count], current = v[i]
            let inFront = current.z >= Self.near, wasInFront = previous.z >= Self.near
            if inFront != wasInFront { out.append(screen(crossing(previous, current))) }
            if inFront { out.append(screen(current)) }
        }
        return out
    }

    /// One straight line on screen, cut where it passes behind the camera, or nil if
    /// it's wholly behind. Allocates nothing, since the grid and streets call it tens of
    /// thousands of times a frame.
    func segment(_ a: MKMapPoint, _ b: MKMapPoint) -> (CGPoint, CGPoint)? {
        var ha = homogeneous(a), hb = homogeneous(b)
        let aIn = ha.z >= Self.near, bIn = hb.z >= Self.near
        guard aIn || bIn else { return nil }
        if !aIn { ha = crossing(ha, hb) }
        if !bIn { hb = crossing(ha, hb) }
        return (screen(ha), screen(hb))
    }

    private func crossing(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        a + (b - a) * ((Self.near - a.z) / (b.z - a.z))
    }

    /// Screen points per map point in the middle of the screen, to decide what's
    /// worth drawing at this zoom and how big a cloud right by the camera may get.
    var centreScale: Double {
        ellipse(centre: centre, radius: 1000).width / 2000
    }

    /// A circle on the ground as it looks on screen: squashed when the map is tilted.
    /// Null if it's behind the camera.
    func ellipse(centre: MKMapPoint, radius: Double) -> CGRect {
        guard isInFront(centre) else { return .null }
        let c = point(centre)
        let east = point(MKMapPoint(x: centre.x + radius, y: centre.y))
        let south = point(MKMapPoint(x: centre.x, y: centre.y + radius))
        let rx = hypot(east.x - c.x, east.y - c.y)
        let ry = hypot(south.x - c.x, south.y - c.y)
        return CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
    }

    /// Whether `other` puts the ground under a screen of `size` within `points` of
    /// where this one does, checked at its corners and middle (bar the far distance
    /// and sky near the horizon). Two unmeasured projections match.
    func matches(_ other: Projection, size: CGSize, within points: Double = 0.1) -> Bool {
        guard isValid, other.isValid else { return isValid == other.isValid }
        guard let m = relative(to: other) else { return false }
        for (fx, fy) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0), (0.5, 0.5)] {
            let p = CGPoint(x: fx * Double(size.width), y: fy * Double(size.height))
            if other.isFar(p, far: BakeFrame.far) { continue }
            let v = m * SIMD3(Double(p.x), Double(p.y), 1)
            guard v.z > 0, abs(v.x / v.z - Double(p.x)) <= points, abs(v.y / v.z - Double(p.y)) <= points else { return false }
        }
        return true
    }

    // MARK: For warping a bake

    /// Normalised ground (map points less `origin`, over `unit`) to screen points.
    private var groundToScreen: simd_double3x3? {
        guard let h else { return nil }
        let w = width
        return simd_double3x3(rows: [
            SIMD3(h[0] * w, h[1] * w, h[2] * w),
            SIMD3(h[3] * w, h[4] * w, h[5] * w),
            SIMD3(h[6], h[7], 1),
        ])
    }

    /// Screen points on `other`'s camera to screen points on this one, through the
    /// ground they both see. Worked out relative to each one's own origin, so the huge
    /// numbers map points are never multiplied together.
    func relative(to other: Projection) -> simd_double3x3? {
        guard let now = groundToScreen, let then = other.groundToScreen, abs(then.determinant) > 1e-300 else { return nil }
        let s = other.unit / unit
        let between = simd_double3x3(rows: [
            SIMD3(s, 0, (other.origin.x - origin.x) / unit),
            SIMD3(0, s, (other.origin.y - origin.y) / unit),
            SIMD3(0, 0, 1),
        ])
        return now * between * then.inverse
    }

    /// The screen row at column `x` above which the ground is more than `far` times as
    /// far from the camera as the 10%, 40% spot, or nil if no such row (a flat map).
    func farRow(atX x: Double, far: Double) -> Double? {
        guard let m = groundToScreen, abs(m.determinant) > 1e-300 else { return nil }
        // Depth at a screen point is 1 / the last term of its ground point, unprojected.
        let inverse = m.inverse
        let a = inverse[0][2], b = inverse[1][2], c = inverse[2][2]
        // The last term grows down the screen as the ground nears the camera. If it
        // doesn't, the far side isn't above.
        guard b > 1e-12 else { return nil }
        let row = (1 / far - a * x - c) / b
        return row.isFinite ? row : nil
    }

    /// Whether the ground under a screen point is more than `far` times as far away
    /// as the 10%, 40% spot, or is sky.
    func isFar(_ p: CGPoint, far: Double) -> Bool {
        guard let m = groundToScreen, abs(m.determinant) > 1e-300 else { return false }
        let g = m.inverse * SIMD3(Double(p.x), Double(p.y), 1)
        return g.z < 1 / far
    }

    /// The eight unknowns of the homography taking four ground points to four screen
    /// points, by Gaussian elimination.
    private static func solve(ground: [(Double, Double)], screen: [(Double, Double)]) -> [Double]? {
        var m: [[Double]] = []
        for ((x, y), (u, v)) in zip(ground, screen) {
            m.append([x, y, 1, 0, 0, 0, -x * u, -y * u, u])
            m.append([0, 0, 0, x, y, 1, -x * v, -y * v, v])
        }
        for col in 0..<8 {
            guard let pivot = (col..<8).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0..<8 where row != col {
                let f = m[row][col] / m[col][col]
                guard f != 0 else { continue }
                for k in col...8 { m[row][k] -= f * m[col][k] }
            }
        }
        return (0..<8).map { m[$0][8] / m[$0][$0] }
    }
}
