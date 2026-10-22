import MapKit
import SwiftUI

/// A colour both renderers can use: SwiftUI's for the Canvas, Core Graphics' for a bake.
nonisolated struct SceneColour: Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let white = SceneColour(red: 1, green: 1, blue: 1)
    static let orange = SceneColour(red: 1, green: 0.47, blue: 0.18)

    func color(_ alpha: Double) -> Color { Color(red: red, green: green, blue: blue).opacity(alpha) }
    func cg(_ alpha: Double) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// What the clouds look like from one camera at one moment: where every puff is and
/// how faded, the dashed grid and streets, and the holes over walked tiles. Worked
/// out once, then drawn either into the live Canvas or into a bake's bitmap, so the
/// two renderers can't drift apart.
nonisolated struct CloudScene {
    struct Placed {
        var variant: Int
        var rect: CGRect
        var top: CGRect
        var fade: Double
    }

    struct Road {
        var path: Path
        var kind: RoadLine.Kind
    }

    struct PlacedMist {
        var rect: CGRect
        var fade: Double
    }

    /// A four-pointed star over mist that's just cleared, in screen points.
    struct Sparkle {
        var centre: CGPoint
        var radius: Double
        var alpha: Double
    }

    /// What the zoom-dependent choices are made from, normally the whole field. A
    /// patch of it drawn on its own (tiles clearing over a bake) passes the whole
    /// field's, so it makes the same choices as the bake round it.
    struct Reference {
        var radius: Double?
        var hasPuffs: Bool

        init(_ field: CloudField, leaving: [CloudField.Puff] = []) {
            radius = (field.puffs.first ?? leaving.first)?.radius
            hasPuffs = !field.puffs.isEmpty
        }
    }

    /// Below this many points across, a puff is drawn as just its top. Its shadow
    /// and underside fade in up to twice this.
    static let simplePuff = 8.0
    static let gridColour = SceneColour(red: 0.42, green: 0.5, blue: 0.62)
    static let roadColour = SceneColour(red: 0.36, green: 0.45, blue: 0.6)
    /// Morning haze: paler and far more see-through than the clouds, so a misty tile
    /// still reads as cleared.
    static let mistColour = SceneColour(red: 0.93, green: 0.95, blue: 0.99)
    static let mistOpacity = 0.42
    static let sparkleColour = SceneColour(red: 1, green: 0.97, blue: 0.82)
    /// Sparkles only once a tile's at least this many points across.
    static let sparkleTile = 10.0

    var placed: [Placed] = []
    /// How much of the shadows and undersides show, 0 zoomed right out.
    var detail = 0.0
    var grid: Path?
    var gridFade = 0.0
    /// The places' outlines, which the streets and holes are cut to.
    var roadClip: Path?
    var roads: [Road] = []
    var erasers: [CGRect] = []
    var mist: [PlacedMist] = []
    var sparkles: [Sparkle] = []

    var isEmpty: Bool { placed.isEmpty && mist.isEmpty && sparkles.isEmpty }

    /// `bounds` is what's being drawn, in screen points; puffs are kept if they reach
    /// within `puffMargin` of its size of it.
    init(
        field: CloudField, leaving: [CloudField.Puff] = [], leavingMist: [CloudField.MistPatch] = [], reveal: Double = 1,
        fresh: Set<CloudField.Tile> = [], projection: Projection, bounds: CGRect, clock: Double, puffMargin: Double = 0.2,
        reference: Reference? = nil
    ) {
        let reference = reference ?? Reference(field, leaving: leaving)
        let visible = bounds.insetBy(dx: -bounds.width * puffMargin, dy: -bounds.height * puffMargin)
        let ease = 1 - pow(1 - reveal, 3)
        let centreScale = projection.centreScale

        func drift(_ rect: CGRect, _ phase: Double) -> CGRect {
            let dx = sin(clock * 0.23 + phase) * 0.07 * rect.width
            let dy = cos(clock * 0.19 + phase * 1.7) * 0.06 * rect.height
            let swell = 1 + 0.05 * sin(clock * 0.31 + phase * 2.3)
            return rect.offsetBy(dx: dx, dy: dy).insetBy(dx: rect.width * (1 - swell) / 2, dy: rect.height * (1 - swell) / 2)
        }

        // Where each cloud is: bobbing gently around its tile and swelling a touch.
        for puff in field.puffs {
            let base = Self.capped(projection.ellipse(centre: puff.centre, radius: puff.radius), radius: puff.radius, centreScale: centreScale)
            guard base.intersects(visible) else { continue }
            placed.append(Placed(variant: puff.variant, rect: drift(base, puff.phase), top: drift(base, puff.phase + 0.7), fade: 1))
        }
        for puff in leaving {
            let radius = puff.radius * (1 + 0.5 * ease)
            let base = Self.capped(projection.ellipse(centre: puff.centre, radius: radius), radius: radius, centreScale: centreScale)
            guard base.intersects(visible) else { continue }
            placed.append(Placed(variant: puff.variant, rect: drift(base, puff.phase), top: drift(base, puff.phase + 0.7), fade: 1 - ease))
        }

        // Haze over misty tiles, and over ones just walked again fading away under a
        // few sparkles: a lighter touch than clouds parting.
        for patch in field.mist {
            let rect = Self.capped(projection.ellipse(centre: patch.centre, radius: patch.radius), radius: patch.radius, centreScale: centreScale)
            guard rect.intersects(visible) else { continue }
            mist.append(PlacedMist(rect: rect, fade: 1))
        }
        if reveal < 1 {
            for patch in leavingMist {
                let rect = Self.capped(projection.ellipse(centre: patch.centre, radius: patch.radius), radius: patch.radius, centreScale: centreScale)
                guard rect.intersects(visible) else { continue }
                mist.append(PlacedMist(rect: rect, fade: 1 - ease))
                sparkles += Self.sparkles(over: rect, tile: patch.tile.hex, reveal: reveal)
            }
        }
        guard !placed.isEmpty else { return }

        // Zoomed out, a puff is only a few points across and its shadow and underside
        // barely show, so they fade away and only the tops are drawn.
        let puffSize = (reference.radius ?? 0) * 2 * centreScale
        detail = min(1, max(0, (puffSize - Self.simplePuff) / Self.simplePuff))
        // Screen points per map point mid-screen, to decide what's worth drawing at this zoom.
        let scale: Double? = reference.hasPuffs ? centreScale : nil

        // A faint dashed honeycomb over the clouds, fading in as you zoom closer.
        if let scale, scale > 0.15, !field.gridEdges.isEmpty {
            var path = Path()
            var i = 0
            let near = bounds.insetBy(dx: -40, dy: -40)
            let area = Self.dashArea(bounds)
            while i < field.gridEdges.count {
                if let (a, b) = projection.segment(field.gridEdges[i], field.gridEdges[i + 1]), near.contains(a) || near.contains(b),
                   let cut = Self.cut(a, b, to: area, pattern: 7) {
                    path.move(to: cut.from)
                    path.addLine(to: cut.to)
                }
                i += 2
            }
            grid = path
            gridFade = min(1, (scale - 0.15) / 0.2)
        }

        // The hidden streets as light dashed lines, inside the place only.
        if let scale, scale > 0.05 {
            var clip = Path()
            for ring in field.outline {
                clip.addLines(projection.polygon(ring))
                clip.closeSubpath()
            }
            roadClip = clip
            // Only the bits on screen. Zoomed in, every street in every place adds up to
            // hundreds of thousands of points of dashed line, which is slow to dash.
            let onScreen = bounds.insetBy(dx: -20, dy: -20)
            let area = Self.dashArea(bounds)
            for kind in [RoadLine.Kind.road, .path] where kind == .road || scale > 0.12 {
                var path = Path()
                let pattern = Double(Self.roadStyle(kind).dash.reduce(0, +))
                for line in field.lines where line.kind == kind {
                    var drawing = false
                    for j in line.points.indices.dropFirst() {
                        guard let (a, b) = projection.segment(line.points[j - 1], line.points[j]),
                              onScreen.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))),
                              let cut = Self.cut(a, b, to: area, pattern: pattern)
                        else {
                            drawing = false
                            continue
                        }
                        if !drawing || cut.startCut { path.move(to: cut.from) }
                        path.addLine(to: cut.to)
                        drawing = !cut.endCut
                    }
                }
                roads.append(Road(path: path, kind: kind))
            }
        }

        // Soft holes over walked tiles. New ones open up rather than just appearing.
        for clearing in field.clearings {
            let grow = fresh.contains(clearing.tile) ? 0.3 + 0.7 * ease : 1
            let radius = clearing.radius * grow
            let rect = Self.capped(projection.ellipse(centre: clearing.centre, radius: radius), radius: radius, centreScale: centreScale)
            guard rect.intersects(visible) else { continue }
            erasers.append(rect)
        }
    }

    /// How far round what's drawn a dashed line is kept: a line running off towards a
    /// tilted camera, or across a camera MapKit's midway through flying, can be millions
    /// of points long, and Core Graphics works out every dash along it, on screen or
    /// not. One that long took a bake minutes, and none came after it.
    static func dashArea(_ bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: -bounds.width, dy: -bounds.height)
    }

    /// A line cut down to `area`, or nil if it misses it. Its start only moves on by
    /// whole dash patterns, `pattern` points long, so the dashes stay put as it's cut.
    static func cut(_ a: CGPoint, _ b: CGPoint, to area: CGRect, pattern: Double) -> (from: CGPoint, to: CGPoint, startCut: Bool, endCut: Bool)? {
        let ax = Double(a.x), ay = Double(a.y)
        let dx = Double(b.x) - ax, dy = Double(b.y) - ay
        guard ax.isFinite, ay.isFinite, dx.isFinite, dy.isFinite else { return nil }
        // Liang-Barsky: how far along the line it enters and leaves the area.
        var enter = 0.0, leave = 1.0
        for (p, q) in [(-dx, ax - Double(area.minX)), (dx, Double(area.maxX) - ax), (-dy, ay - Double(area.minY)), (dy, Double(area.maxY) - ay)] {
            if p == 0 {
                if q < 0 { return nil }
            } else if p < 0 {
                enter = max(enter, q / p)
            } else {
                leave = min(leave, q / p)
            }
        }
        guard enter <= leave else { return nil }
        let length = hypot(dx, dy)
        if enter > 0, length > 0, pattern > 0 {
            enter = (enter * length / pattern).rounded(.down) * pattern / length
        }
        func at(_ t: Double) -> CGPoint { CGPoint(x: ax + dx * t, y: ay + dy * t) }
        return (at(enter), leave < 1 ? at(leave) : b, enter > 0, leave < 1)
    }

    /// Clouds right by a tilted camera would balloon to fill the screen, so none get
    /// more than twice the size they'd be mid-screen.
    static func capped(_ rect: CGRect, radius: Double, centreScale: Double) -> CGRect {
        guard !rect.isNull else { return rect }
        let limit = radius * 2 * centreScale * 2
        let biggest = max(rect.width, rect.height)
        guard limit > 0, biggest > limit else { return rect }
        let f = limit / biggest
        return CGRect(x: rect.midX - rect.width * f / 2, y: rect.midY - rect.height * f / 2, width: rect.width * f, height: rect.height * f)
    }

    /// A handful of stars over a tile whose mist is clearing, each twinkling in and out
    /// at its own moment as it drifts up, always the same way for the same tile.
    /// None when the tile's too small on screen to see them.
    static func sparkles(over rect: CGRect, tile: Hex, reveal: Double) -> [Sparkle] {
        // The patch is bigger than the tile; the tile's about three quarters of it.
        let size = min(rect.width, rect.height) / CloudField.mistSpread
        guard size >= sparkleTile else { return [] }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(CloudField.hash(tile))))
        var out: [Sparkle] = []
        for _ in 0..<5 {
            let start = rng.unit() * 0.45
            let t = (reveal - start) / 0.5
            let x = rect.midX + (rng.unit() - 0.5) * size * 0.8
            let y = rect.midY + (rng.unit() - 0.5) * size * 0.6
            let scale = 0.8 + rng.unit() * 0.5
            guard t > 0, t < 1 else { continue }
            let pulse = sin(t * .pi)
            out.append(Sparkle(centre: CGPoint(x: x, y: y - t * size * 0.15), radius: (2.5 + 3.5 * pulse) * scale, alpha: pulse))
        }
        return out
    }

    static func star(_ sparkle: Sparkle) -> CGPath {
        let r = sparkle.radius, inner = r * 0.3
        let c = sparkle.centre
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + inner, y: c.y - inner),
            CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x + inner, y: c.y + inner),
            CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - inner, y: c.y + inner),
            CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x - inner, y: c.y - inner),
        ])
        path.closeSubpath()
        return path
    }

    static func roadStyle(_ kind: RoadLine.Kind) -> (alpha: Double, width: Double, dash: [CGFloat]) {
        kind == .road ? (0.6, 1.8, [6, 5]) : (0.45, 1.4, [3, 4])
    }

    /// Into a bitmap, in the same order and with the same blending as the Canvas.
    func draw(in context: CGContext, sprites: CloudSprites) {
        guard !isEmpty else { return }
        drawClouds(in: context, sprites: sprites)
        drawMist(in: context, sprites: sprites)
    }

    private func drawClouds(in context: CGContext, sprites: CloudSprites) {
        guard !placed.isEmpty else { return }
        // Shadows on the ground, with the sun to the north-west.
        if detail > 0 {
            for p in placed {
                context.setAlpha(0.35 * p.fade * detail)
                let r = p.rect
                Self.draw(sprites.shadows[p.variant], in: r.offsetBy(dx: r.width * 0.15, dy: r.height * 0.18), on: context)
            }
            context.setAlpha(1)
        }

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        // Every shaded underside first, then every sunlit top, so the middle of the
        // blanket is one continuous white and the grey only shows round its edges.
        if detail > 0 {
            for p in placed {
                context.setAlpha(p.fade * detail)
                Self.draw(sprites.bases[p.variant], in: p.rect, on: context)
            }
        }
        for p in placed {
            context.setAlpha(p.fade)
            Self.draw(sprites.tops[p.variant], in: p.top, on: context)
        }
        context.setAlpha(1)
        context.setLineCap(.round)
        if let grid {
            context.addPath(grid.cgPath)
            context.setStrokeColor(Self.gridColour.cg(0.5 * gridFade))
            context.setLineWidth(1.2)
            context.setLineDash(phase: 0, lengths: [3, 4])
            context.strokePath()
        }
        if let roadClip {
            // Stays for the holes too, as it does in the Canvas.
            context.addPath(roadClip.cgPath)
            context.clip()
            for road in roads {
                let style = Self.roadStyle(road.kind)
                context.addPath(road.path.cgPath)
                context.setStrokeColor(Self.roadColour.cg(style.alpha))
                context.setLineWidth(style.width)
                context.setLineDash(phase: 0, lengths: style.dash)
                context.strokePath()
            }
        }
        context.setBlendMode(.destinationOut)
        for rect in erasers {
            Self.draw(sprites.eraser, in: rect, on: context)
        }
        context.restoreGState()
        context.endTransparencyLayer()
    }

    /// The haze on a layer of its own, so overlapping patches make one even wash,
    /// then the sparkles. As `drawMist` in Clouds.swift's CloudPainter.
    private func drawMist(in context: CGContext, sprites: CloudSprites) {
        if !mist.isEmpty {
            context.saveGState()
            context.setAlpha(Self.mistOpacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for patch in mist {
                context.setAlpha(patch.fade)
                Self.draw(sprites.mist, in: patch.rect, on: context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
        guard !sparkles.isEmpty else { return }
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(1)
        context.setLineJoin(.round)
        for sparkle in sparkles {
            let star = Self.star(sparkle)
            context.addPath(star)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.35 * sparkle.alpha))
            context.strokePath()
            context.addPath(star)
            context.setFillColor(Self.sparkleColour.cg(sparkle.alpha))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// An image the right way up in a context whose y runs down the screen.
    static func draw(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// The colour-coded tiles that show while you drag the map: green where you've
/// walked, orange where you walked this time, white outlines still to walk, and grey
/// where there's no street or path (those clear when you walk beside them).
nonisolated struct HoneycombScene {
    static let green = SceneColour(red: 0.36, green: 0.72, blue: 0.4)
    static let grey = SceneColour(red: 0.35, green: 0.37, blue: 0.42)
    static let styles: [(fill: SceneColour, fillAlpha: Double, stroke: SceneColour, strokeAlpha: Double)] = [
        (green, 0.3, green, 0.9),  // visited
        (green, 0.12, green, 0.45),  // cleared
        (.white, 0.06, .white, 0.85),  // open
        (grey, 0.35, grey, 0.5),  // blocked
        (.orange, 0.35, .orange, 1),  // this walk
    ]

    /// One path per style, in drawing order.
    var paths: [(style: Int, path: Path)] = []

    init(field: CloudField, walkTiles: Set<CloudField.Tile>, projection: Projection, bounds: CGRect) {
        let near = bounds.insetBy(dx: -60, dy: -60)
        var byStyle: [Int: Path] = [:]
        for outline in field.outlines {
            let c = projection.point(outline.centre)
            guard near.contains(c), projection.isInFront(outline.centre) else { continue }
            let style = walkTiles.contains(outline.tile) ? 4 : Self.index(outline.kind)
            var path = byStyle[style] ?? Path()
            path.addLines(outline.corners.map(projection.point))
            path.closeSubpath()
            byStyle[style] = path
        }
        paths = byStyle.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func index(_ kind: CloudField.Outline.Kind) -> Int {
        switch kind {
        case .visited: 0
        case .cleared: 1
        case .open: 2
        case .blocked: 3
        }
    }

    func draw(in context: inout GraphicsContext, opacity: Double) {
        for (index, path) in paths {
            let style = Self.styles[index]
            context.fill(path, with: .color(style.fill.color(style.fillAlpha * opacity)))
            context.stroke(path, with: .color(style.stroke.color(style.strokeAlpha * opacity)), lineWidth: 1.2)
        }
    }

    func draw(in context: CGContext) {
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(1.2)
        for (index, path) in paths {
            let style = Self.styles[index]
            context.addPath(path.cgPath)
            context.setFillColor(style.fill.cg(style.fillAlpha))
            context.fillPath()
            context.addPath(path.cgPath)
            context.setStrokeColor(style.stroke.cg(style.strokeAlpha))
            context.strokePath()
        }
    }
}
