import CoreImage
import MapKit
import os

/// Everything the cloud layer draws, worked out up front in map points.
nonisolated struct CloudField: Sendable {
    struct Puff: Sendable {
        /// Where the cloud sprite goes. Bigger than the hex, so neighbours merge into one blanket.
        var rect: MKMapRect
        /// The hex underneath, for clipping the dotted roads.
        var corners: [MKMapPoint]
        var variant: Int
    }

    struct Line: Sendable {
        var points: [MKMapPoint]
        var rect: MKMapRect
        var kind: RoadLine.Kind
    }

    /// Cloud sprite radius as a multiple of the hex size.
    static let spread = 1.6
    /// Radius of the soft hole cut over each walked hex, as a multiple of the hex size.
    /// Clouds spill well past their own hex, so without this a walk down a single
    /// street gets swallowed by the clouds either side of it.
    static let clearing = 1.25

    var puffs: [Puff] = []
    /// Where to cut the clouds away over walked hexes.
    var clearings: [MKMapRect] = []
    var lines: [Line] = []
    /// Cloud sprite radius in map points.
    var reach = 0.0

    init() {}

    /// With `blanket`, clouds also cover tiles in the boundary that have no street or
    /// path (bush, wetland, canals), so the whole suburb is one sheet of cloud.
    /// Without it they're left clear, because they don't count towards 100%.
    init(city: City, blanket: Bool = false) {
        let grid = city.grid
        let metres = MKMapPointsPerMeterAtLatitude(grid.projection.origin.lat)
        let radius = grid.size * Self.spread * metres
        reach = radius * 1.25
        let hole = grid.size * Self.clearing * metres
        clearings = city.visited.map { hex in
            let centre = MKMapPoint(grid.projection.unproject(grid.centre(of: hex)).cl)
            return MKMapRect(x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2)
        }
        let hexSize = grid.size * metres
        let clouded = blanket ? city.boundaryHexes().union(city.tiles) : city.tiles
        puffs = clouded.subtracting(city.visited)
            .map { hex in
                // Nudge and resize each cloud a little, always the same way for the same
                // hex, so the blanket doesn't sit on an obvious honeycomb.
                var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Self.hash(hex))))
                let centre = MKMapPoint(grid.projection.unproject(grid.centre(of: hex)).cl)
                let x = centre.x + (rng.unit() - 0.5) * 0.5 * hexSize
                let y = centre.y + (rng.unit() - 0.5) * 0.5 * hexSize
                let r = radius * (0.88 + rng.unit() * 0.35)
                return Puff(
                    rect: MKMapRect(x: x - r, y: y - r, width: r * 2, height: r * 2),
                    corners: grid.corners(of: hex).map { MKMapPoint($0.cl) },
                    variant: Int(rng.next() % UInt64(CloudSprites.count))
                )
            }
            // North first, so clouds further south sit in front of them.
            .sorted { $0.rect.midY < $1.rect.midY }
        lines = (city.roads ?? []).map { road in
            let points = road.points.map { MKMapPoint($0.cl) }
            return Line(points: points, rect: Self.bounds(of: points), kind: road.kind)
        }
    }

    private static func hash(_ hex: Hex) -> Int {
        (Int(hex.q) &* 73_856_093) ^ (Int(hex.r) &* 19_349_663)
    }

    private static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? 0, y = ys.min() ?? 0
        return MKMapRect(x: x, y: y, width: (xs.max() ?? 0) - x, height: (ys.max() ?? 0) - y)
    }
}

/// One overlay covering the whole city. MapKit draws it in tiles on background
/// threads, so the field it reads is behind a lock.
nonisolated final class CloudOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    private let state: OSAllocatedUnfairLock<CloudField>

    init(boundary: Boundary, field: CloudField) {
        let b = boundary.bounds
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: b.north, longitude: b.west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: b.south, longitude: b.east))
        let rect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
        // Leave room for clouds spilling past the edge and their shadows.
        boundingMapRect = rect.insetBy(dx: -field.reach * 2, dy: -field.reach * 2)
        coordinate = boundary.centre.cl
        state = OSAllocatedUnfairLock(initialState: field)
    }

    var field: CloudField {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

nonisolated final class CloudRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? CloudOverlay else { return }
        let field = overlay.field
        let near = mapRect.insetBy(dx: -field.reach, dy: -field.reach)
        let puffs = field.puffs.filter { $0.rect.intersects(near) }
        guard !puffs.isEmpty else { return }
        let sprites = CloudSprites.shared
        context.interpolationQuality = .high

        // Shadows on the ground, with the sun to the north-west. One transparency
        // layer so overlapping shadows don't stack up darker.
        let shift = field.reach * 0.3
        context.saveGState()
        context.setAlpha(0.35)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for puff in puffs {
            draw(sprites.shadows[puff.variant], in: rect(for: puff.rect.offsetBy(dx: shift, dy: shift * 1.2)), context)
        }
        context.endTransparencyLayer()
        context.restoreGState()

        // Every shaded underside first, then every sunlit top, so the middle of the
        // blanket is one continuous white and the grey only shows round its edges.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for puff in puffs {
            draw(sprites.bases[puff.variant], in: rect(for: puff.rect), context)
        }
        for puff in puffs {
            draw(sprites.tops[puff.variant], in: rect(for: puff.rect), context)
        }
        let clearings = field.clearings.filter { $0.intersects(near) }
        if !clearings.isEmpty {
            context.setBlendMode(.destinationOut)
            for clearing in clearings {
                draw(sprites.eraser, in: rect(for: clearing), context)
            }
        }
        context.endTransparencyLayer()

        // Zoomed out, the dots just turn into noise: roads from a couple of km across, paths
        // closer in. MapKit can draw tiles a zoom level up, so these are higher than they look.
        if zoomScale > 0.025 {
            let lines = field.lines.filter { $0.rect.intersects(mapRect) && ($0.kind == .road || zoomScale > 0.05) }
            drawRoads(lines, over: puffs, zoomScale: zoomScale, in: context)
        }
    }

    /// Images are stored y-up and the map draws y-down, so flip each one.
    private func draw(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// The hidden streets as dotted lines, only over clouded hexes.
    private func drawRoads(_ lines: [CloudField.Line], over puffs: [CloudField.Puff], zoomScale: MKZoomScale, in context: CGContext) {
        guard !lines.isEmpty else { return }
        let clip = CGMutablePath()
        for puff in puffs {
            clip.addLines(between: puff.corners.map { point(for: $0) })
            clip.closeSubpath()
        }
        context.saveGState()
        context.addPath(clip)
        context.clip()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for kind in [RoadLine.Kind.road, .path] {
            let path = CGMutablePath()
            for line in lines where line.kind == kind {
                path.addLines(between: line.points.map { point(for: $0) })
            }
            // Sizes in screen points, converted to map points.
            context.setLineWidth((kind == .road ? 4.5 : 3.5) / zoomScale)
            context.setLineDash(phase: 0, lengths: [0.01 / zoomScale, (kind == .road ? 11 : 8) / zoomScale])
            context.setStrokeColor(CGColor(red: 0.32, green: 0.42, blue: 0.6, alpha: kind == .road ? 0.75 : 0.55))
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
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
