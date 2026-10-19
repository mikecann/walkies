import CoreImage
import MapKit
import SwiftUI

/// Everything the cloud layer draws, worked out in map points whenever the tiles change.
nonisolated struct CloudField: Sendable {
    struct Puff: Sendable {
        var hex: Hex
        var centre: MKMapPoint
        /// Bigger than the hex, so neighbours merge into one blanket.
        var radius: Double
        var variant: Int
        /// Where this cloud is in its drift, so they don't all bob in time.
        var phase: Double
    }

    struct Clearing: Sendable {
        var hex: Hex
        var centre: MKMapPoint
        var radius: Double
    }

    struct Line: Sendable {
        var points: [MKMapPoint]
        var kind: RoadLine.Kind
    }

    /// Cloud sprite radius as a multiple of the hex size.
    static let spread = 1.6
    /// Radius of the soft hole cut over each walked hex, as a multiple of the hex size.
    /// Clouds spill well past their own hex, so without this a walk down a single
    /// street gets swallowed by the clouds either side of it.
    static let clearing = 1.25

    /// North first, so clouds further south sit in front of them.
    var puffs: [Puff] = []
    /// Where to cut the clouds away over walked hexes.
    var clearings: [Clearing] = []
    var lines: [Line] = []
    /// The suburb's outline, so the dotted roads stop at its edge.
    var outline: [[MKMapPoint]] = []
    /// Stickers still hidden under the clouds, which twinkle to give you something to aim for.
    var hints: [MKMapPoint] = []
    /// A tile's centre-to-corner size in map points, for sizing things to the zoom.
    var tileRadius = 0.0

    init() {}

    init(city: City, hints hidden: [Hex] = []) {
        let grid = city.grid
        let cover = city.cloudCover()
        let metres = MKMapPointsPerMeterAtLatitude(grid.projection.origin.lat)
        let hexSize = grid.size * metres
        func centre(of hex: Hex) -> MKMapPoint {
            MKMapPoint(grid.projection.unproject(grid.centre(of: hex)).cl)
        }

        clearings = cover.clear.map { Clearing(hex: $0, centre: centre(of: $0), radius: hexSize * Self.clearing) }
        puffs = cover.clouded
            .map { hex in
                // Nudge and resize each cloud a little, always the same way for the same
                // hex, so the blanket doesn't sit on an obvious honeycomb.
                var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Self.hash(hex))))
                let c = centre(of: hex)
                return Puff(
                    hex: hex,
                    centre: MKMapPoint(x: c.x + (rng.unit() - 0.5) * 0.5 * hexSize, y: c.y + (rng.unit() - 0.5) * 0.5 * hexSize),
                    radius: hexSize * Self.spread * (0.88 + rng.unit() * 0.35),
                    variant: Int(rng.next() % UInt64(CloudSprites.count)),
                    phase: rng.unit() * 2 * .pi
                )
            }
            .sorted { $0.centre.y < $1.centre.y }
        lines = (city.roads ?? []).map { Line(points: $0.points.map { MKMapPoint($0.cl) }, kind: $0.kind) }
        outline = city.boundary.polygons.map { $0.outer.map { MKMapPoint($0.cl) } }
        hints = hidden.map(centre)
        tileRadius = hexSize
    }

    private static func hash(_ hex: Hex) -> Int {
        (Int(hex.q) &* 73_856_093) ^ (Int(hex.r) &* 19_349_663)
    }
}

/// Lets the cloud layer ask the map where things are on screen right now.
final class MapHandle {
    weak var map: MKMapView?
}

/// The clouds, drawn on top of the map about 30 times a second so they can drift
/// and breathe. They follow the map by asking it where each cloud is on screen.
struct CloudLayer: View {
    let field: CloudField
    /// Changes whenever the field does, to spot tiles that have just cleared.
    let key: String
    let handle: MapHandle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: (key: String, field: CloudField)?
    /// Clouds over tiles that have just cleared, fading out as they drift apart.
    @State private var leaving: [CloudField.Puff] = []
    @State private var changedAt = Date.distantPast

    static let revealTime = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                guard let map = handle.map, size.width > 0 else { return }
                let now = timeline.date
                let clock = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
                let reveal = min(1, now.timeIntervalSince(changedAt) / Self.revealTime)
                CloudPainter(
                    field: field, leaving: reveal < 1 ? leaving : [], reveal: reveal,
                    fresh: Set(leaving.map(\.hex)), projection: Projection(map: map),
                    bounds: CGRect(origin: .zero, size: size), clock: clock
                )
                .draw(in: &context)
            }
        }
        .allowsHitTesting(false)
        .onAppear { shown = (key, field) }
        .onChange(of: key) {
            // Only animate tiles clearing in the same city, not a whole new one appearing.
            if let old = shown, old.key.prefix(36) == key.prefix(36) {
                let still = Set(field.puffs.map(\.hex))
                leaving = old.field.puffs.filter { !still.contains($0.hex) }
                changedAt = .now
            } else {
                leaving = []
            }
            shown = (key, field)
        }
    }
}

/// Turns map points into screen points. Flat maps are one cheap affine transform;
/// tilted ones ask MapKit point by point.
private struct Projection {
    let map: MKMapView
    private let affine: CGAffineTransform?

    init(map: MKMapView) {
        self.map = map
        if map.camera.pitch < 1 {
            let p0 = MKMapPoint(map.centerCoordinate)
            let d = 1000.0
            let s0 = map.convert(p0.coordinate, toPointTo: map)
            let s1 = map.convert(MKMapPoint(x: p0.x + d, y: p0.y).coordinate, toPointTo: map)
            let s2 = map.convert(MKMapPoint(x: p0.x, y: p0.y + d).coordinate, toPointTo: map)
            let a = (s1.x - s0.x) / d, b = (s1.y - s0.y) / d
            let c = (s2.x - s0.x) / d, dd = (s2.y - s0.y) / d
            affine = CGAffineTransform(a: a, b: b, c: c, d: dd, tx: s0.x - a * p0.x - c * p0.y, ty: s0.y - b * p0.x - dd * p0.y)
        } else {
            affine = nil
        }
    }

    func point(_ p: MKMapPoint) -> CGPoint {
        if let affine { return CGPoint(x: p.x, y: p.y).applying(affine) }
        return map.convert(p.coordinate, toPointTo: map)
    }

    /// A circle on the ground as it looks on screen: squashed when the map is tilted.
    func ellipse(centre: MKMapPoint, radius: Double) -> CGRect {
        let c = point(centre)
        let rx = hypot(point(MKMapPoint(x: centre.x + radius, y: centre.y)).x - c.x, point(MKMapPoint(x: centre.x + radius, y: centre.y)).y - c.y)
        let ry = hypot(point(MKMapPoint(x: centre.x, y: centre.y + radius)).x - c.x, point(MKMapPoint(x: centre.x, y: centre.y + radius)).y - c.y)
        return CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
    }
}

private struct CloudPainter {
    let field: CloudField
    let leaving: [CloudField.Puff]
    /// 0 to 1 through the latest tiles clearing.
    let reveal: Double
    let fresh: Set<Hex>
    let projection: Projection
    let bounds: CGRect
    let clock: Double

    func draw(in context: inout GraphicsContext) {
        let sprites = CloudSprites.shared
        let visible = bounds.insetBy(dx: -bounds.width * 0.2, dy: -bounds.height * 0.2)
        let ease = 1 - pow(1 - reveal, 3)

        // Where each cloud is this frame: bobbing gently around its tile and swelling a touch.
        var placed: [(puff: CloudField.Puff, rect: CGRect, top: CGRect, fade: Double)] = []
        for puff in field.puffs {
            let base = projection.ellipse(centre: puff.centre, radius: puff.radius)
            guard base.intersects(visible) else { continue }
            placed.append((puff, drift(base, puff.phase), drift(base, puff.phase + 0.7), 1))
        }
        for puff in leaving {
            let base = projection.ellipse(centre: puff.centre, radius: puff.radius * (1 + 0.5 * ease))
            guard base.intersects(visible) else { continue }
            placed.append((puff, drift(base, puff.phase), drift(base, puff.phase + 0.7), 1 - ease))
        }
        guard !placed.isEmpty else { return }

        let bases = sprites.bases.map { context.resolve(Image(decorative: $0, scale: 1)) }
        let tops = sprites.tops.map { context.resolve(Image(decorative: $0, scale: 1)) }
        let shadows = sprites.shadows.map { context.resolve(Image(decorative: $0, scale: 1)) }
        let eraser = context.resolve(Image(decorative: sprites.eraser, scale: 1))

        // Shadows on the ground, with the sun to the north-west.
        context.drawLayer { layer in
            layer.opacity = 0.35
            for p in placed {
                layer.opacity = 0.35 * p.fade
                let r = p.rect
                layer.draw(shadows[p.puff.variant], in: r.offsetBy(dx: r.width * 0.15, dy: r.height * 0.18))
            }
        }

        context.drawLayer { layer in
            // Every shaded underside first, then every sunlit top, so the middle of the
            // blanket is one continuous white and the grey only shows round its edges.
            for p in placed {
                layer.opacity = p.fade
                layer.draw(bases[p.puff.variant], in: p.rect)
            }
            for p in placed {
                layer.opacity = p.fade
                layer.draw(tops[p.puff.variant], in: p.top)
            }
            layer.opacity = 1
            drawRoads(in: &layer)

            // Soft holes over walked tiles. New ones open up rather than just appearing.
            layer.blendMode = .destinationOut
            for clearing in field.clearings {
                let grow = fresh.contains(clearing.hex) ? 0.3 + 0.7 * ease : 1
                let rect = projection.ellipse(centre: clearing.centre, radius: clearing.radius * grow)
                guard rect.intersects(visible) else { continue }
                layer.draw(eraser, in: rect)
            }
        }

        drawHints(in: &context)
    }

    /// A small gold sparkle over each hidden sticker, glinting on its own beat.
    private func drawHints(in context: inout GraphicsContext) {
        guard let first = field.hints.first else { return }
        // Small glints when the whole suburb's on screen, proper sparkles up close.
        let tile = projection.ellipse(centre: first, radius: field.tileRadius).width / 2
        let scale = min(1, max(0.35, tile / 40))
        for (i, hint) in field.hints.enumerated() {
            let at = projection.point(hint)
            guard bounds.insetBy(dx: -20, dy: -20).contains(at) else { continue }
            let beat = 0.5 + 0.5 * sin(clock * 1.6 + Double(i) * 2.399)
            let size = (9 + 5 * beat) * scale
            var star = Path()
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4 - .pi / 2
                let r = k.isMultiple(of: 2) ? size : size * 0.28
                let p = CGPoint(x: at.x + cos(angle) * r, y: at.y + sin(angle) * r)
                k == 0 ? star.move(to: p) : star.addLine(to: p)
            }
            star.closeSubpath()
            context.drawLayer { glow in
                glow.addFilter(.shadow(color: Color(red: 1, green: 0.75, blue: 0.2).opacity(0.9), radius: 6))
                glow.opacity = 0.55 + 0.45 * beat
                glow.fill(star, with: .color(Color(red: 1, green: 0.86, blue: 0.4)))
            }
        }
    }

    private func drift(_ rect: CGRect, _ phase: Double) -> CGRect {
        let dx = sin(clock * 0.23 + phase) * 0.07 * rect.width
        let dy = cos(clock * 0.19 + phase * 1.7) * 0.06 * rect.height
        let swell = 1 + 0.05 * sin(clock * 0.31 + phase * 2.3)
        return rect.offsetBy(dx: dx, dy: dy).insetBy(dx: rect.width * (1 - swell) / 2, dy: rect.height * (1 - swell) / 2)
    }

    /// The hidden streets as dotted lines, inside the suburb only.
    private func drawRoads(in context: inout GraphicsContext) {
        // A ground distance in screen points, to decide when the dots are worth drawing.
        guard let first = field.puffs.first else { return }
        let scale = projection.ellipse(centre: first.centre, radius: 100).width / 200
        guard scale > 0.05 else { return }

        var clip = Path()
        for ring in field.outline {
            clip.addLines(ring.map(projection.point))
            clip.closeSubpath()
        }
        context.clip(to: clip)

        for kind in [RoadLine.Kind.road, .path] where kind == .road || scale > 0.12 {
            var path = Path()
            for line in field.lines where line.kind == kind {
                path.addLines(line.points.map(projection.point))
            }
            context.stroke(
                path,
                with: .color(Color(red: 0.32, green: 0.42, blue: 0.6).opacity(kind == .road ? 0.75 : 0.55)),
                style: StrokeStyle(lineWidth: kind == .road ? 4.5 : 3.5, lineCap: .round, dash: [0.01, kind == .road ? 11 : 8])
            )
        }
    }
}

/// A handful of cumulus puffs drawn once at launch. Each is a few big soft circles,
/// split into a blue-grey underside and a sunlit white top nudged towards the
/// north-west. Also a blurred silhouette of each for its shadow, and a soft eraser.
nonisolated final class CloudSprites: @unchecked Sendable {
    static let count = 8
    static let shared = CloudSprites()

    let bases: [CGImage]
    let tops: [CGImage]
    let shadows: [CGImage]
    let eraser: CGImage

    private init() {
        var bases: [CGImage] = []
        var tops: [CGImage] = []
        var shadows: [CGImage] = []
        for i in 0..<Self.count {
            let circles = Self.circles(seed: UInt64(i + 1))
            bases.append(Self.base(circles, size: 384))
            tops.append(Self.top(circles, size: 384))
            shadows.append(Self.shadow(circles, size: 160))
        }
        self.bases = bases
        self.tops = tops
        self.shadows = shadows
        eraser = Self.eraser(size: 128)
    }

    /// Circles as (x, y, radius) in a -1...1 square with y up.
    private static func circles(seed: UInt64) -> [SIMD3<Double>] {
        var rng = SplitMix64(seed: seed)
        var out = [SIMD3(0, 0, 0.55)]
        let ring = 4 + Int(rng.next() % 3)
        for i in 0..<ring {
            let angle = Double(i) / Double(ring) * 2 * .pi + rng.unit() * 0.8
            let distance = 0.28 + rng.unit() * 0.12
            out.append(SIMD3(cos(angle) * distance, sin(angle) * distance, 0.33 + rng.unit() * 0.12))
        }
        return out
    }

    private static func base(_ circles: [SIMD3<Double>], size: Int) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        let shade = CGColor(red: 0.76, green: 0.8, blue: 0.87, alpha: 1)
        fill(circles, in: context, size: s, scale: 1, shift: SIMD2(0, 0), colours: [shade, shade, shade.copy(alpha: 0)!], hardness: 0.65)
        return blur(context.makeImage()!, sigma: s * 0.01)
    }

    /// A touch greyer towards the edge, so overlapping tops leave faint billows.
    private static func top(_ circles: [SIMD3<Double>], size: Int) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        let edge = CGColor(red: 0.93, green: 0.945, blue: 0.97, alpha: 1)
        fill(
            circles, in: context, size: s, scale: 0.84, shift: SIMD2(-0.05, 0.06),
            colours: [CGColor(gray: 1, alpha: 1), edge, edge.copy(alpha: 0)!], hardness: 0.5
        )
        return blur(context.makeImage()!, sigma: s * 0.01)
    }

    /// Soft-edged circles: the first colour in the middle, the second at `hardness`
    /// of the radius, then fading to the third at the edge.
    private static func fill(
        _ circles: [SIMD3<Double>], in context: CGContext, size s: Double, scale: Double,
        shift: SIMD2<Double>, colours: [CGColor], hardness: Double
    ) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colours as CFArray,
            locations: [0, hardness, 1]
        )!
        for c in circles {
            let centre = CGPoint(x: (c.x * scale + shift.x + 1) / 2 * s, y: (c.y * scale + shift.y + 1) / 2 * s)
            context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: c.z * scale / 2 * s, options: [])
        }
    }

    private static func shadow(_ circles: [SIMD3<Double>], size: Int) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for c in circles {
            let r = c.z / 2 * s
            context.addEllipse(in: CGRect(x: (c.x + 1) / 2 * s - r, y: (c.y + 1) / 2 * s - r, width: r * 2, height: r * 2))
        }
        context.fillPath()
        return blur(context.makeImage()!, sigma: s * 0.05)
    }

    /// Fully opaque in the middle, fading out over the outer third.
    private static func eraser(size: Int) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        let centre = CGPoint(x: s / 2, y: s / 2)
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 0.68, 1]
        )!
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: s / 2, options: [])
        return context.makeImage()!
    }

    private static func blur(_ cgImage: CGImage, sigma: Double) -> CGImage {
        let image = CIImage(cgImage: cgImage)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
        return CIContext().createCGImage(blurred, from: image.extent)!
    }

    private static func bitmap(_ size: Int) -> CGContext {
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}

nonisolated struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
