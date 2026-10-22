import CoreGraphics
import MapKit
import SwiftUI

/// What to bake: the clouds as `frame`'s camera sees them, drifted to `clock`.
nonisolated struct BakeJob: Sendable {
    var frame: BakeFrame
    var field: CloudField
    var fieldKey: String
    var theme: String
    var clock: Double
    /// Also bake the honeycomb, for while you drag.
    var honeycomb: Bool
    var walkTiles: Set<CloudField.Tile>
    /// Tells one `walkTiles` from another without comparing them.
    var walkKey: Int
    /// The field on screen when this was asked for, to work out which clouds clear.
    var previous: CloudField?
    var previousKey: String?
}

/// A finished bake: pictures of the job's clouds and honeycomb, each covering the
/// frame's box of its camera's screen.
nonisolated final class CloudBake: @unchecked Sendable {
    let job: BakeJob
    let clouds: CGImage?
    let honeycomb: CGImage?
    /// The clouds in the previous field that aren't in this one, if it's tiles clearing.
    let leaving: [CloudField.Puff]
    /// Mist in the previous field that's gone from this one: tiles walked again.
    let leavingMist: [CloudField.MistPatch]
    let milliseconds: Double

    var frame: BakeFrame { job.frame }
    var field: CloudField { job.field }
    var fieldKey: String { job.fieldKey }
    var theme: String { job.theme }
    var clock: Double { job.clock }

    init(
        job: BakeJob, clouds: CGImage?, honeycomb: CGImage?, leaving: [CloudField.Puff],
        leavingMist: [CloudField.MistPatch] = [], milliseconds: Double
    ) {
        self.job = job
        self.clouds = clouds
        self.honeycomb = honeycomb
        self.leaving = leaving
        self.leavingMist = leavingMist
        self.milliseconds = milliseconds
    }
}

/// Every place's clouds at once, from straight above, north up, small and soft: the
/// tops of the puffs only, with no shadows, grid or streets, as zoomed right out.
/// It doesn't depend on the camera, so it's made as soon as the tiles are known and
/// again only when they or the look change, and stands in wherever the sharp bake
/// doesn't reach (opening the app, zooming out past it, a fast pan) until the next
/// one's ready. See `OverviewPlacement` for how it's put on screen.
nonisolated final class CloudOverview: @unchecked Sendable {
    let image: CGImage?
    /// The map points it covers. Its pixels are its points.
    let area: MKMapRect
    let pixels: CGSize
    let fieldKey: String
    let theme: String
    let places: [UUID]
    let milliseconds: Double

    /// The ground to its pixels.
    var projection: Projection { Self.projection(area: area, pixels: pixels) }

    init(image: CGImage?, area: MKMapRect, pixels: CGSize, fieldKey: String, theme: String, places: [UUID], milliseconds: Double) {
        self.image = image
        self.area = area
        self.pixels = pixels
        self.fieldKey = fieldKey
        self.theme = theme
        self.places = places
        self.milliseconds = milliseconds
    }

    static func projection(area: MKMapRect, pixels: CGSize) -> Projection {
        let w = Double(pixels.width), h = Double(pixels.height)
        let ground = [
            MKMapPoint(x: area.minX, y: area.minY), MKMapPoint(x: area.maxX, y: area.minY),
            MKMapPoint(x: area.maxX, y: area.maxY), MKMapPoint(x: area.minX, y: area.maxY),
        ]
        let screen = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
        return Projection(ground: ground, screen: screen, width: w, centre: MKMapPoint(x: area.midX, y: area.midY))
    }
}

/// Draws bakes into bitmaps, off the main thread.
nonisolated enum CloudBakery {
    /// The honeycomb's only lines and flat fills, faint and moving, so it bakes a bit softer.
    static let honeycombScale = 0.75

    static func bake(_ job: BakeJob) -> CloudBake {
        let started = DispatchTime.now().uptimeNanoseconds
        let sprites = CloudSprites.sprites(for: job.theme)
        var leaving: [CloudField.Puff] = []
        var leavingMist: [CloudField.MistPatch] = []
        if let old = job.previous, job.previousKey != job.fieldKey, old.places == job.field.places {
            let still = Set(job.field.puffs.map(\.tile))
            leaving = old.puffs.filter { !still.contains($0.tile) }
            leavingMist = CloudField.clearedMist(from: old, to: job.field)
        }
        let frame = job.frame
        let scene = CloudScene(field: job.field, projection: frame.projection, bounds: frame.rect, clock: job.clock, puffMargin: 0.05)
        let clouds = render(frame.rect, scale: frame.scale) { scene.draw(in: $0, sprites: sprites) }
        var honeycomb: CGImage?
        if job.honeycomb {
            let tiles = HoneycombScene(field: job.field, walkTiles: job.walkTiles, projection: frame.projection, bounds: frame.rect)
            honeycomb = render(frame.rect, scale: frame.scale * honeycombScale) { tiles.draw(in: $0) }
        }
        let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        return CloudBake(job: job, clouds: clouds, honeycomb: honeycomb, leaving: leaving, leavingMist: leavingMist, milliseconds: took)
    }

    /// The overview's most pixels: 2 MB at 4 bytes each, which a phone draws in a
    /// fraction of a second.
    static let overviewPixels = 500_000.0
    /// And no wider or taller than this.
    static let overviewSide = 2048.0

    static func overview(field: CloudField, fieldKey: String, theme: String, clock: Double, pixels budget: Double = overviewPixels) -> CloudOverview {
        let started = DispatchTime.now().uptimeNanoseconds
        // Room round every puff for its drift and swell.
        var area = MKMapRect.null
        for puff in field.puffs {
            let r = puff.radius * 1.3
            area = area.union(MKMapRect(x: puff.centre.x - r, y: puff.centre.y - r, width: r * 2, height: r * 2))
        }
        for patch in field.mist {
            let r = patch.radius
            area = area.union(MKMapRect(x: patch.centre.x - r, y: patch.centre.y - r, width: r * 2, height: r * 2))
        }
        func done(_ image: CGImage?, _ area: MKMapRect, _ pixels: CGSize) -> CloudOverview {
            let took = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            return CloudOverview(image: image, area: area, pixels: pixels, fieldKey: fieldKey, theme: theme, places: field.places, milliseconds: took)
        }
        guard !area.isNull, area.width > 0, area.height > 0 else { return done(nil, .null, .zero) }
        var scale = (budget / (area.width * area.height)).squareRoot()
        scale = min(scale, overviewSide / max(area.width, area.height))
        let pixels = CGSize(width: max(1, (area.width * scale).rounded(.up)), height: max(1, (area.height * scale).rounded(.up)))
        // Out to whole pixels, so the picture's pixels are exactly its points.
        area.size = MKMapSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        var simple = field
        simple.lines = []
        simple.gridEdges = []
        simple.outline = []
        simple.outlines = []
        let bounds = CGRect(origin: .zero, size: pixels)
        var scene = CloudScene(field: simple, projection: CloudOverview.projection(area: area, pixels: pixels), bounds: bounds, clock: clock, puffMargin: 0.05)
        scene.detail = 0
        let sprites = CloudSprites.sprites(for: theme)
        let image = render(bounds, scale: 1) { scene.draw(in: $0, sprites: sprites) }
        return done(image, area, pixels)
    }

    /// A bitmap of `rect` (in screen points) at `scale` pixels to the point, drawn in
    /// screen points with y running down. Laid out as the screen's own are (BGRA,
    /// premultiplied), so Core Animation can show it without converting it.
    static func render(_ rect: CGRect, scale: Double, draw: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int((Double(rect.width) * scale).rounded(.up)))
        let height = max(1, Int((Double(rect.height) * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        draw(context)
        return context.makeImage()
    }

    // MARK: Tiles clearing

    /// Room round a puff for its drift, swell and shadow.
    private static func grown(_ r: CGRect) -> CGRect {
        let pad = r.insetBy(dx: -r.width * 0.12, dy: -r.height * 0.12)
        return pad.union(pad.offsetBy(dx: r.width * 0.15, dy: r.height * 0.18))
    }

    /// The box round tiles clearing, in the bake's screen points and on its pixel grid,
    /// that's drawn live over the bake while they open. Nil if they're nowhere on it.
    static func revealPatch(field: CloudField, leaving: [CloudField.Puff], leavingMist: [CloudField.MistPatch] = [], frame: BakeFrame) -> CGRect? {
        let p = frame.projection
        let scale = p.centreScale
        var box = CGRect.null
        for puff in leaving {
            // As big as they get, half as big again as they part.
            let radius = puff.radius * 1.5
            let r = CloudScene.capped(p.ellipse(centre: puff.centre, radius: radius), radius: radius, centreScale: scale)
            if !r.isNull { box = box.union(grown(r)) }
        }
        for patch in leavingMist {
            // Room for the sparkles drifting up off it.
            let r = CloudScene.capped(p.ellipse(centre: patch.centre, radius: patch.radius), radius: patch.radius, centreScale: scale)
            if !r.isNull { box = box.union(r.insetBy(dx: -8, dy: -8 - r.height * 0.15)) }
        }
        let fresh = Set(leaving.map(\.tile))
        for clearing in field.clearings where fresh.contains(clearing.tile) {
            let r = CloudScene.capped(p.ellipse(centre: clearing.centre, radius: clearing.radius), radius: clearing.radius, centreScale: scale)
            if !r.isNull { box = box.union(r.insetBy(dx: -2, dy: -2)) }
        }
        box = box.intersection(frame.rect)
        guard !box.isNull, !box.isEmpty else { return nil }
        // Out to whole pixels of the bake, so the patch lines up with it exactly.
        let s = frame.scale, o = frame.rect.origin
        let x0 = ((box.minX - o.x) * s).rounded(.down), y0 = ((box.minY - o.y) * s).rounded(.down)
        let x1 = ((box.maxX - o.x) * s).rounded(.up), y1 = ((box.maxY - o.y) * s).rounded(.up)
        return CGRect(x: o.x + x0 / s, y: o.y + y0 / s, width: (x1 - x0) / s, height: (y1 - y0) / s)
    }

    /// Just the bits of `field` that could show in `area`, so drawing round tiles
    /// clearing every frame doesn't go through every cloud in every place.
    static func near(_ area: CGRect, in field: CloudField, projection p: Projection) -> CloudField {
        let scale = p.centreScale
        var out = CloudField()
        out.places = field.places
        out.outline = field.outline
        out.puffs = field.puffs.filter { puff in
            let r = CloudScene.capped(p.ellipse(centre: puff.centre, radius: puff.radius), radius: puff.radius, centreScale: scale)
            return !r.isNull && grown(r).intersects(area)
        }
        out.clearings = field.clearings.filter { clearing in
            let r = CloudScene.capped(p.ellipse(centre: clearing.centre, radius: clearing.radius), radius: clearing.radius, centreScale: scale)
            return !r.isNull && r.intersects(area)
        }
        out.mist = field.mist.filter { patch in
            let r = CloudScene.capped(p.ellipse(centre: patch.centre, radius: patch.radius), radius: patch.radius, centreScale: scale)
            return !r.isNull && r.intersects(area)
        }
        let gridArea = area.insetBy(dx: -40, dy: -40)
        var i = 0
        while i + 1 < field.gridEdges.count {
            if let (a, b) = p.segment(field.gridEdges[i], field.gridEdges[i + 1]), gridArea.contains(a) || gridArea.contains(b) {
                out.gridEdges.append(field.gridEdges[i])
                out.gridEdges.append(field.gridEdges[i + 1])
            }
            i += 2
        }
        let roadArea = area.insetBy(dx: -20, dy: -20)
        out.lines = field.lines.filter { line in
            line.points.indices.dropFirst().contains { j in
                guard let (a, b) = p.segment(line.points[j - 1], line.points[j]) else { return false }
                return roadArea.intersects(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            }
        }
        return out
    }
}
