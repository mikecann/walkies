import Foundation
import CoreGraphics
import QuartzCore
import simd

/// Which renderer draws the clouds. `-cloudRenderer live` on launch keeps the old one,
/// that draws every puff in a Canvas each frame, to compare the two on the same phone.
nonisolated enum CloudRenderer: String, Sendable {
    /// Baked into a picture off the main thread, warped by Core Animation each frame.
    case baked
    /// Drawn puff by puff in a SwiftUI Canvas each frame.
    case live

    static let current: CloudRenderer = LaunchArguments.value(after: "-cloudRenderer") == "live" ? .live : .baked
}

/// Launch arguments, read by hand: `UserDefaults` would read `-perfRun -cloudRenderer live`
/// as perfRun = "-cloudRenderer".
nonisolated enum LaunchArguments {
    static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

/// Where a baked picture of the clouds was drawn from: the camera's projection at the
/// time, and the box of its screen the picture covers (the screen plus a margin all
/// round, stopping short of the horizon), in screen points. The picture is `scale`
/// pixels to the point.
nonisolated struct BakeFrame: Sendable {
    let id: Int
    let projection: Projection
    let rect: CGRect
    let scale: Double
    /// Drawn rough and wide while the camera moved, to keep up. Redone sharp once it stops.
    let draft: Bool

    var pixelWidth: Int { max(1, Int((Double(rect.width) * scale).rounded(.up))) }
    var pixelHeight: Int { max(1, Int((Double(rect.height) * scale).rounded(.up))) }

    /// How far past each edge of the screen a bake reaches, as a fraction of its size.
    static let margin = 0.12
    /// A still bake's pixels per point: the phone's own, up to 2. The clouds are soft,
    /// so 2 looks the same on a 3x screen and is under half the pixels to bake.
    static let maxScale = 2.0
    /// While the map's moving: further, so a pan doesn't run off the edge before the next one's ready.
    static let draftMargin = 0.45
    /// And a point a pixel, as it takes a fraction of the time.
    static let draftScale = 1.0
    /// The most pixels in a bake, 12 MB at 4 bytes each: a bigger screen bakes a touch softer.
    static let maxPixels = 3_000_000.0
    /// No bigger than this either way, which every GPU can hold as one texture.
    static let maxSide = 4096.0
    /// The ground can be at most this many times as far from the camera as the 10%,
    /// 40% spot before a bake stops: the horizon itself is infinitely far, and clouds
    /// near it are specks.
    static let far = 12.0

    nonisolated(unsafe) private static var lastID = 0
    private static let idLock = NSLock()

    private static func nextID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        lastID += 1
        return lastID
    }

    init(projection: Projection, rect: CGRect, scale: Double, draft: Bool) {
        id = Self.nextID()
        self.projection = projection
        self.rect = rect
        self.scale = scale
        self.draft = draft
    }

    /// The frame for baking what `projection` sees on a screen of `size`, on a phone
    /// with `displayScale` pixels to the point.
    static func around(_ projection: Projection, size: CGSize, displayScale: Double, draft: Bool) -> BakeFrame {
        let region = region(projection, size: size, margin: draft ? draftMargin : margin)
        let left = Double(region.minX), right = Double(region.maxX), top = Double(region.minY), bottom = Double(region.maxY)
        var scale = draft ? min(draftScale, displayScale) : min(maxScale, displayScale)
        let pixels = (right - left) * scale * (bottom - top) * scale
        if pixels > maxPixels { scale *= (maxPixels / pixels).squareRoot() }
        scale = min(scale, maxSide / max(right - left, bottom - top))
        return BakeFrame(projection: projection, rect: region, scale: scale, draft: draft)
    }

    /// A screen of `size` and `margin` of its size all round, in screen points,
    /// stopping where the ground's too far away: above that row there's only horizon.
    static func region(_ projection: Projection, size: CGSize, margin: Double) -> CGRect {
        let width = Double(size.width), height = Double(size.height)
        let left = -width * margin, right = width * (1 + margin)
        var top = -height * margin
        let bottom = height * (1 + margin)
        for x in [left, right] {
            if let row = projection.farRow(atX: x, far: far), row > top { top = min(row, bottom - 1) }
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// How a bake has to be warped to sit on the map as it is now: one perspective
/// transform from the bake's screen points to today's, through the same ground the
/// projection measures. Also says when a bake has gone stale. Nil if some of the
/// bake would be behind the camera now, which can't be drawn.
nonisolated struct BakeWarp {
    /// Bake screen points to screen points now.
    let matrix: simd_double3x3
    let inverse: simd_double3x3
    let frame: BakeFrame

    /// Past this much bigger or smaller, a still bake is redone.
    static let stretch = 1.25
    /// Or turned past about 4°.
    static let turn = 0.07
    /// While the map moves: further either way before a new bake's asked for.
    static let movingStretch = 2.0
    /// About 9°.
    static let movingTurn = 0.15
    /// And half the margin used up on any side.
    static let movingReach = 0.5
    /// The screen's corners and middle, as fractions of its width and height.
    private static let checks: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1), (0.5, 0.5)]

    init?(now: Projection, frame: BakeFrame) {
        guard var m = now.relative(to: frame.projection) else { return nil }
        // Scaled so the last term is 1, as Core Animation expects. Always by a positive
        // number: flipping the sign would put the picture behind the camera.
        let last = m[2][2]
        guard last > 0, last.isFinite else { return nil }
        m = (1 / last) * m
        guard abs(m.determinant) > 1e-300 else { return nil }
        // Every corner of the bake in front of the camera, so it never wraps round behind.
        let r = frame.rect
        for (x, y) in [(r.minX, r.minY), (r.maxX, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY)] {
            guard (m * SIMD3(Double(x), Double(y), 1)).z > 0 else { return nil }
        }
        matrix = m
        inverse = m.inverse
        self.frame = frame
    }

    /// A bake screen point to the screen now, or nil if it's behind the camera.
    func map(_ p: CGPoint) -> CGPoint? { Self.apply(matrix, p) }

    /// A screen point now back to the bake's screen, or nil if it's behind the bake's camera.
    func unmap(_ p: CGPoint) -> CGPoint? { Self.apply(inverse, p) }

    private static func apply(_ m: simd_double3x3, _ p: CGPoint) -> CGPoint? {
        let v = m * SIMD3(Double(p.x), Double(p.y), 1)
        guard v.z > 0 else { return nil }
        return CGPoint(x: v.x / v.z, y: v.y / v.z)
    }

    /// For a layer showing the bake, with its anchor point at the top left (0, 0), its
    /// position at the screen's (0, 0) and its bounds the size of the bake's box: takes
    /// the layer's own points (the box, from its top left) to the screen now. Core
    /// Animation treats points as rows, [x y z 1] times the matrix, so it's this
    /// warp, after moving the box's corner to the origin, transposed into 4x4.
    var layerTransform: CATransform3D {
        let r = frame.rect
        let shift = simd_double3x3(rows: [SIMD3(1, 0, Double(r.minX)), SIMD3(0, 1, Double(r.minY)), SIMD3(0, 0, 1)])
        return Self.layerTransform(matrix * shift)
    }

    /// A homography from a layer's own points to the screen, as Core Animation takes it.
    static func layerTransform(_ m: simd_double3x3) -> CATransform3D {
        // m[col][row].
        var t = CATransform3DIdentity
        t.m11 = m[0][0]; t.m21 = m[1][0]; t.m31 = 0; t.m41 = m[2][0]
        t.m12 = m[0][1]; t.m22 = m[1][1]; t.m32 = 0; t.m42 = m[2][1]
        t.m13 = 0; t.m23 = 0; t.m33 = 1; t.m43 = 0
        t.m14 = m[0][2]; t.m24 = m[1][2]; t.m34 = 0; t.m44 = m[2][2]
        return t
    }

    /// Whether a screen of `size` now is still well served by the bake: all of it
    /// inside the bake (bar sky and the far distance the bake stops short of), and
    /// nowhere stretched, squashed or turned so much that the clouds would look off.
    ///
    /// While the map moves, `moving` lets it stretch and turn further (it's hard to
    /// see mid-pan) but asks again once the screen's used up half the margin on any
    /// side, so the next bake's ready before the edge shows.
    func fits(size: CGSize, now: Projection, moving: Bool = false) -> Bool {
        let width = Double(size.width), height = Double(size.height)
        let r = frame.rect
        let reach = moving ? Self.movingReach : 1
        let left = Double(r.minX) * reach
        let right = width + (Double(r.maxX) - width) * reach
        let top = r.minY < 0 ? Double(r.minY) * reach : Double(r.minY)
        let bottom = height + (Double(r.maxY) - height) * reach
        let stretch = moving ? Self.movingStretch : Self.stretch
        let turn = moving ? Self.movingTurn : Self.turn
        for (fx, fy) in Self.checks {
            let screen = CGPoint(x: fx * width, y: fy * height)
            // Up by the horizon the bake doesn't reach, and needn't.
            if now.isFar(screen, far: BakeFrame.far) { continue }
            guard let b = unmap(screen) else { return false }
            let bx = Double(b.x), by = Double(b.y)
            if bx < left || bx > right || by < top || by > bottom { return false }
            if !looksRight(at: b, stretch: stretch, turn: turn) { return false }
        }
        return true
    }

    /// The warp's local stretch and turn at a bake point: within `stretch` either way
    /// along both axes, and turned less than `turn` radians.
    private func looksRight(at p: CGPoint, stretch: Double, turn: Double = .infinity) -> Bool {
        let (a, b, c, d) = jacobian(at: p)
        let (biggest, smallest) = Self.stretches(a, b, c, d)
        if biggest > stretch || smallest < 1 / stretch { return false }
        return abs(atan2(c - b, a + d)) < turn
    }

    /// How much a 2x2 matrix stretches things most and least: its two singular values,
    /// from the closed form.
    static func stretches(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> (biggest: Double, smallest: Double) {
        let e = (a + d) / 2, f = (a - d) / 2, g = (c + b) / 2, h = (c - b) / 2
        let q = hypot(e, h), r = hypot(f, g)
        return (q + r, abs(q - r))
    }

    /// Past this much bigger or smaller, a still bake isn't shown at all: the overview
    /// stands in until the next one's ready.
    static let showable = 3.0
    /// While the map moves, much further: a bake blown up soft or shrunk small for the
    /// moment the next one takes is hard to see mid-gesture, and far better than the
    /// live Canvas making every frame late.
    static let movingShowable = 6.0

    /// Whether the bake's worth showing on a screen of `size` now: the middle of the
    /// screen (or low down, if the middle's by the horizon) is on it, and not
    /// stretched or squashed past `showable` (or `movingShowable`). False for one from
    /// a camera that's since flown far off, which would otherwise be warped off the
    /// screen or to a speck.
    func shows(size: CGSize, now: Projection, moving: Bool = false) -> Bool {
        let width = Double(size.width), height = Double(size.height)
        var screen = CGPoint(x: width / 2, y: height / 2)
        if now.isFar(screen, far: BakeFrame.far) { screen.y = height * 0.9 }
        guard let b = unmap(screen), frame.rect.contains(b) else { return false }
        return looksRight(at: b, stretch: moving ? Self.movingShowable : Self.showable)
    }

    /// Whether the bake reaches past every edge of a screen of `size` now (bar sky and
    /// the far distance), so nothing need show under it.
    func covers(size: CGSize, now: Projection) -> Bool {
        let width = Double(size.width), height = Double(size.height)
        let r = frame.rect.insetBy(dx: -0.5, dy: -0.5)
        for (fx, fy) in Self.checks {
            let screen = CGPoint(x: fx * width, y: fy * height)
            if now.isFar(screen, far: BakeFrame.far) { continue }
            guard let b = unmap(screen), r.contains(b) else { return false }
        }
        return true
    }

    /// d(screen now) / d(bake screen) at a bake point: (dx/dx, dx/dy, dy/dx, dy/dy).
    func jacobian(at p: CGPoint) -> (Double, Double, Double, Double) {
        Self.jacobian(matrix, at: p)
    }

    /// d(out) / d(in) of a homography at a point: (dx/dx, dx/dy, dy/dx, dy/dy).
    static func jacobian(_ m: simd_double3x3, at p: CGPoint) -> (Double, Double, Double, Double) {
        let x = Double(p.x), y = Double(p.y)
        // Rows of m: m[col][row].
        let w = m[0][2] * x + m[1][2] * y + m[2][2]
        let px = (m[0][0] * x + m[1][0] * y + m[2][0]) / w
        let py = (m[0][1] * x + m[1][1] * y + m[2][1]) / w
        return (
            (m[0][0] - px * m[0][2]) / w, (m[1][0] - px * m[1][2]) / w,
            (m[0][1] - py * m[0][2]) / w, (m[1][1] - py * m[1][2]) / w
        )
    }

    /// Whether the bake already matches the screen now to within `points` everywhere
    /// on it, so redoing it wouldn't change anything.
    func exact(size: CGSize, points: Double = 0.3) -> Bool {
        for (fx, fy) in Self.checks {
            let screen = CGPoint(x: fx * Double(size.width), y: fy * Double(size.height))
            guard let b = unmap(screen) else { return false }
            if abs(b.x - screen.x) > points || abs(b.y - screen.y) > points { return false }
        }
        return true
    }
}

/// When to bake the clouds again, worked out from what's on screen and what's wanted.
/// The rules from the Android version: a new bake for new tiles or a new look, from
/// the same camera and drift if they still fit so it drops straight in; while the map
/// moves, a rough wide one only once the screen's about to run off the last; once it
/// stops, a sharp one from exactly where it is; and when it's been still a while, the
/// same again with the clouds drifted on.
nonisolated enum BakePolicy {
    /// The camera's still once it hasn't moved for this long, in seconds.
    static let settle = 0.25
    /// How often the clouds' drift is baked again while the map's still.
    static let driftPeriod = 2.5
    /// How long a drift bake fades in over the last.
    static let driftFade = 1.0
    /// A bake still not done after `giveUp` seconds is given up on and another asked
    /// for, so one that's stuck can't leave the clouds where they were for good.
    /// Never sooner than this: bakes take 1 to 2 s on an iPhone XS Max and up to
    /// 2.5 s in a Debug build in the simulator, and giving up on those only to ask
    /// again wastes the bake thread.
    static let minimumGiveUp = 3.0

    /// Three times as long as the last bake took, from asking to having it, or twice
    /// the minimum before there's been one (the first bake loads the sprites).
    static func giveUp(lastBake: Double?) -> Double {
        guard let lastBake else { return minimumGiveUp * 2 }
        return max(minimumGiveUp, lastBake * 3)
    }

    /// How long a bake fades in over whatever stood in for it, and that then fades out.
    static let fade = 0.3
    /// Once the map's still, the overview stands in on its own up to this many screen
    /// points to its pixel. Any softer (zoomed in, with no bake to show at all) and
    /// the live clouds do, until the sharp bake's done. While the map moves, or under
    /// a bake that shows, it's drawn however soft.
    static let overviewStretch = 3.0
    /// The first bake waits up to this long for the overview to be made, in seconds.
    static let overviewWait = 1.0

    struct Shown: Sendable {
        var frame: BakeFrame
        var fieldKey: String
        var theme: String
        var clock: Double
        /// Whether the honeycomb on hand was baked from this frame with today's walk.
        var honeycombCurrent: Bool
    }

    struct Wanted: Sendable {
        var fieldKey: String
        var theme: String
    }

    struct Request: Equatable, Sendable {
        enum Where: Equatable, Sendable {
            /// The frame on screen, so the new bake drops straight in.
            case shown
            /// A fresh frame round the camera as it is now.
            case fresh(draft: Bool)
        }
        enum Clock: Equatable, Sendable {
            /// The same drift as what's on screen.
            case shown
            case now
        }
        var frame: Where
        var clock: Clock
        var honeycomb: Bool
    }

    /// What was last asked for, to stop asking again for the same thing.
    struct Asked: Sendable {
        /// The camera's still where it was for the last request.
        var sameCamera: Bool
        var draft: Bool
        var honeycomb: Bool
    }

    /// `fits` and `exact` are about the bake on screen and the camera now (false if
    /// it can't be warped at all). `clock` is the drift now; `drifts` false when
    /// reduce motion is on or the tiles are clearing. `flying` is the camera moving
    /// by itself (MapKit flying it somewhere, as it does on opening), not under a
    /// finger: nothing's baked from round it until it lands, as by then it'd be far
    /// off, and the overview or the live clouds stand in meanwhile.
    static func decide(
        shown: Shown?, wanted: Wanted, fits: Bool, exact: Bool, moving: Bool, dragging: Bool,
        clock: Double, drifts: Bool, asked: Asked?, flying: Bool = false
    ) -> Request? {
        guard let shown, shown.fieldKey == wanted.fieldKey, shown.theme == wanted.theme else {
            // New tiles or a new look. From the same camera and drift as what's on
            // screen if that still fits; mid-pan, the same drift at least.
            if shown == nil { return flying ? nil : Request(frame: .fresh(draft: moving), clock: .now, honeycomb: true) }
            if !fits, flying { return nil }
            return Request(frame: fits ? .shown : .fresh(draft: moving), clock: fits || moving ? .shown : .now, honeycomb: true)
        }
        if flying { return nil }
        if moving {
            // Only once the picture's about to run out, roughly, with the drift held.
            if fits || asked?.sameCamera == true { return nil }
            return Request(frame: .fresh(draft: true), clock: .shown, honeycomb: dragging)
        }
        if !fits || shown.frame.draft || !exact || !shown.honeycombCurrent {
            // Sharpen a rough bake, or one from a camera a little off, from right here.
            if let asked, asked.sameCamera, !asked.draft, asked.honeycomb { return nil }
            return Request(frame: .fresh(draft: false), clock: .shown, honeycomb: true)
        }
        if drifts, clock - shown.clock >= driftPeriod {
            return Request(frame: .shown, clock: .now, honeycomb: false)
        }
        return nil
    }
}

/// Where the overview (every place's clouds from straight above, see `CloudOverview`)
/// goes on screen now. The whole of it can't be warped into perspective, as a tilted
/// camera has some of it behind, so only the window of it the screen can see is: a
/// box turned to the camera's heading, so its near edge runs along the bottom of the
/// screen and none of it's behind the camera.
///
/// Shown as two layers: a window layer clipped to its bounds, warped onto the screen
/// by `transform`, holding the overview's picture turned and moved by `imageTransform`.
nonisolated struct OverviewPlacement {
    /// The window, in its own points (turned overview pixels).
    let windowSize: CGSize
    /// The window's points to the screen now, for a layer anchored at its top left at (0, 0).
    let transform: CATransform3D
    /// The overview's pixels to the window's points.
    let imageTransform: CGAffineTransform
    /// Screen points per overview pixel in the middle of the screen: the more, the softer it looks.
    let stretch: Double
    /// False if none of the overview's on screen now, so there's nothing to show.
    let visible: Bool

    /// How far past each edge of the screen it's shown.
    static let margin = 0.1

    /// `overview` takes the ground to the overview's pixels; it's `pixels` big.
    init?(overview: Projection, pixels: CGSize, now: Projection, size: CGSize) {
        // Screen points now to overview pixels.
        guard let m = overview.relative(to: now), abs(m.determinant) > 1e-300 else { return nil }
        let region = BakeFrame.region(now, size: size, margin: Self.margin)
        var corners: [SIMD2<Double>] = []
        for (x, y) in [(region.minX, region.maxY), (region.maxX, region.maxY), (region.maxX, region.minY), (region.minX, region.minY)] {
            let v = m * SIMD3(Double(x), Double(y), 1)
            guard v.z > 0, v.x.isFinite, v.y.isFinite else { return nil }
            corners.append(SIMD2(v.x / v.z, v.y / v.z))
        }
        // Turned so the bottom of the screen runs along the window's x axis. The ground
        // under any row of the screen is a line that way, all of it as far from the
        // camera, so a box between the bottom and top rows is all in front.
        let along = corners[1] - corners[0]
        guard simd_length(along) > 1e-9 else { return nil }
        let angle = atan2(along.y, along.x)
        let c = cos(angle), s = sin(angle)
        func turn(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y) }
        func box(_ points: [SIMD2<Double>]) -> CGRect {
            let turned = points.map(turn)
            let xs = turned.map(\.x), ys = turned.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let w = Double(pixels.width), h = Double(pixels.height)
        let window = box(corners).intersection(box([SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]))
        imageTransform = CGAffineTransform(a: c, b: -s, c: s, d: c, tx: -window.minX, ty: -window.minY)
        guard !window.isNull, window.width > 0.5, window.height > 0.5 else {
            windowSize = .zero
            transform = CATransform3DIdentity
            stretch = 0
            visible = false
            return
        }
        // The window's points to overview pixels, then to the screen now.
        let wx = Double(window.minX), wy = Double(window.minY)
        let toOverview = simd_double3x3(rows: [
            SIMD3(c, -s, c * wx - s * wy),
            SIMD3(s, c, s * wx + c * wy),
            SIMD3(0, 0, 1),
        ])
        var toScreen = m.inverse * toOverview
        let ww = Double(window.width), wh = Double(window.height)
        let middle = toScreen * SIMD3(ww / 2, wh / 2, 1)
        guard middle.z > 0, middle.z.isFinite else { return nil }
        toScreen = (1 / middle.z) * toScreen
        for (x, y) in [(0.0, 0.0), (ww, 0), (ww, wh), (0, wh)] {
            guard (toScreen * SIMD3(x, y, 1)).z > 0 else { return nil }
        }
        windowSize = window.size
        transform = BakeWarp.layerTransform(toScreen)
        visible = true

        var screen = CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2)
        if now.isFar(screen, far: BakeFrame.far) { screen.y = size.height * 0.9 }
        let o = m * SIMD3(Double(screen.x), Double(screen.y), 1)
        guard o.z > 0 else { return nil }
        let (a, b, cc, d) = BakeWarp.jacobian(m.inverse, at: CGPoint(x: o.x / o.z, y: o.y / o.z))
        stretch = BakeWarp.stretches(a, b, cc, d).biggest
    }
}
