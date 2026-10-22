import CoreImage
import MapKit
import SwiftUI

/// Everything the cloud layer draws, worked out in map points whenever the tiles change.
/// It covers every place you've added at once, on the same world grid.
nonisolated struct CloudField: Sendable {
    /// A world tile. The grid is stateless, so shared tiles deduplicate across places.
    struct Tile: Hashable, Sendable {
        var grid: HexGrid
        var hex: Hex
    }

    struct Puff: Sendable {
        var tile: Tile
        var centre: MKMapPoint
        /// Bigger than the hex, so neighbours merge into one blanket.
        var radius: Double
        var variant: Int
        /// Where this cloud is in its drift, so they don't all bob in time.
        var phase: Double
    }

    struct Clearing: Sendable {
        var tile: Tile
        var centre: MKMapPoint
        var radius: Double
    }

    struct Line: Sendable {
        var points: [MKMapPoint]
        var kind: RoadLine.Kind
    }

    /// A pale haze over a tile you've walked but not for a while (Mist.swift).
    struct MistPatch: Sendable {
        var tile: Tile
        var centre: MKMapPoint
        var radius: Double
    }

    /// A tile for the colour-coded honeycomb that shows while you drag the map.
    struct Outline: Sendable {
        enum Kind: Sendable {
            /// Walked.
            case visited
            /// No street or path, cleared because you walked beside it.
            case cleared
            /// Has a street or path, not walked yet.
            case open
            /// No street or path, still under cloud.
            case blocked
        }
        var tile: Tile
        var kind: Kind
        var centre: MKMapPoint
        var corners: [MKMapPoint]
    }

    /// Cloud sprite radius as a multiple of the hex size.
    static let spread = 1.6
    /// Radius of the soft hole cut over each walked hex, as a multiple of the hex size.
    /// Clouds spill well past their own hex, so without this a walk down a single
    /// street gets swallowed by the clouds either side of it.
    static let clearing = 1.25
    /// Radius of the haze over each misty tile, as a multiple of the hex size: enough
    /// for neighbours to run together into one wash.
    static let mistSpread = 1.3

    /// Which places this covers, so the layer can tell tiles clearing from a place
    /// being added or removed.
    var places: [UUID] = []
    /// North first, so clouds further south sit in front of them.
    var puffs: [Puff] = []
    /// Where to cut the clouds away over walked hexes.
    var clearings: [Clearing] = []
    /// Haze over walked tiles that haven't been walked again for a while.
    var mist: [MistPatch] = []
    var lines: [Line] = []
    /// The places' outlines, so the dotted roads stop at their edges.
    var outline: [[MKMapPoint]] = []
    /// The edges of the tiles under cloud, drawn as a faint dashed grid. Each edge
    /// once, as a pair of points, so shared edges don't double up their dashes.
    var gridEdges: [MKMapPoint] = []
    var outlines: [Outline] = []

    init() {}

    init(city: City) {
        self.init(cities: [city])
    }

    /// With `mistAt`, tiles walked but not walked again for `mistDays` before then get
    /// mist. Without, there's none (the celebration's replays).
    init(cities: [City], mistAt now: Date? = nil, mistDays: Double = Mist.days) {
        places = cities.map(\.id)
        var clouded = Set<Tile>()
        var clear = Set<Tile>()
        var kinds: [Tile: Outline.Kind] = [:]
        for city in cities {
            let cover = city.cloudCover()
            clouded.formUnion(cover.clouded.map { Tile(grid: city.grid, hex: $0) })
            clear.formUnion(cover.clear.map { Tile(grid: city.grid, hex: $0) })
            for hex in cover.blocked { kinds[Tile(grid: city.grid, hex: hex)] = kinds[Tile(grid: city.grid, hex: hex)] ?? .blocked }
            for hex in city.tiles.subtracting(city.visited) { kinds[Tile(grid: city.grid, hex: hex)] = .open }
            for hex in cover.clear.subtracting(city.visited) { kinds[Tile(grid: city.grid, hex: hex)] = .cleared }
            for hex in city.visited { kinds[Tile(grid: city.grid, hex: hex)] = .visited }
        }
        // A border tile walked in one place is walked in the other too.
        clouded.subtract(clear)

        func centre(of tile: Tile) -> MKMapPoint {
            MKMapPoint(tile.grid.projection.unproject(tile.grid.centre(of: tile.hex)).cl)
        }
        func hexSize(_ grid: HexGrid) -> Double {
            grid.size * MKMapSize.world.width / (2 * .pi * WorldProjection.radius)
        }

        clearings = clear.map { Clearing(tile: $0, centre: centre(of: $0), radius: hexSize($0.grid) * Self.clearing) }
        if let now {
            mist = Mist.tiles(in: cities, now: now, days: mistDays)
                .map { Tile(grid: .world, hex: $0) }
                .filter { clear.contains($0) }
                .map { MistPatch(tile: $0, centre: centre(of: $0), radius: hexSize($0.grid) * Self.mistSpread) }
        }
        puffs = clouded
            .map { tile in
                // Nudge and resize each cloud a little, always the same way for the same
                // hex, so the blanket doesn't sit on an obvious honeycomb.
                var rng = SplitMix64(seed: UInt64(bitPattern: Int64(Self.hash(tile.hex))))
                let c = centre(of: tile)
                let size = hexSize(tile.grid)
                return Puff(
                    tile: tile,
                    centre: MKMapPoint(x: c.x + (rng.unit() - 0.5) * 0.5 * size, y: c.y + (rng.unit() - 0.5) * 0.5 * size),
                    radius: size * Self.spread * (0.88 + rng.unit() * 0.35),
                    variant: Int(rng.next() % UInt64(CloudSprites.count)),
                    phase: rng.unit() * 2 * .pi
                )
            }
            .sorted { $0.centre.y < $1.centre.y }
        // Neighbouring places fetch the same streets along their shared edges.
        let roads = Set(cities.flatMap { $0.roads ?? [] })
        lines = roads.map { Line(points: $0.points.map { MKMapPoint($0.cl) }, kind: $0.kind) }
        outline = cities.flatMap { $0.boundary.polygons.map { $0.outer.map { MKMapPoint($0.cl) } } }

        outlines = kinds.map { tile, kind in
            Outline(
                tile: tile, kind: kind, centre: centre(of: tile),
                corners: tile.grid.corners(of: tile.hex).map { MKMapPoint($0.cl) }
            )
        }

        // Edge i runs between corners i and i + 1 and faces this neighbour.
        let facing: [(Int32, Int32)] = [(1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1)]
        for tile in clouded {
            let hex = tile.hex
            let corners = tile.grid.corners(of: hex).map { MKMapPoint($0.cl) }
            for i in 0..<6 {
                let n = Hex(q: hex.q + facing[i].0, r: hex.r + facing[i].1)
                guard !clouded.contains(Tile(grid: tile.grid, hex: n)) || (hex.q, hex.r) < (n.q, n.r) else { continue }
                gridEdges.append(corners[i])
                gridEdges.append(corners[(i + 1) % 6])
            }
        }
    }

    /// Mist in `old` that's gone from `new`: tiles just walked again, to sparkle.
    static func clearedMist(from old: CloudField, to new: CloudField) -> [MistPatch] {
        guard !old.mist.isEmpty else { return [] }
        let still = Set(new.mist.map(\.tile))
        return old.mist.filter { !still.contains($0.tile) }
    }

    static func hash(_ hex: Hex) -> Int {
        (Int(hex.q) &* 73_856_093) ^ (Int(hex.r) &* 19_349_663)
    }
}

/// Lets the cloud layer ask the map where things are on screen right now.
@Observable
final class MapHandle {
    @ObservationIgnored weak var map: MKMapView?
    /// True while the map is being dragged, pinched or flown somewhere, so the
    /// clouds redraw every frame and keep up with it.
    var moving = false {
        didSet { if moving != oldValue { cameraChanged?() } }
    }
    /// Projected by the Canvas for the equipped decorative trail.
    @ObservationIgnored var route: [MKMapPoint] = []
    /// True while your finger's moving the map, for the colour-coded honeycomb.
    var dragging = false {
        didSet { if dragging != oldValue { draggingChangedAt = .now } }
    }
    @ObservationIgnored var draggingChangedAt = Date.distantPast
    /// Set by the `-perfRun` harness while it moves the camera itself, standing in for
    /// a finger on the map. Always false otherwise.
    var simulatedGesture = false {
        didSet { if simulatedGesture != oldValue { draggingChangedAt = .now } }
    }

    // The harness's flag first, so while it's on, `moving` flipping every frame as it
    // sets the camera doesn't redraw SwiftUI views that only read these.
    var isMoving: Bool { simulatedGesture || moving }
    var isDragging: Bool { simulatedGesture || dragging }

    /// Counts every change of the map's camera, for the baked clouds to follow it in
    /// step with MapKit rather than a frame behind.
    @ObservationIgnored private(set) var cameraVersion = 0
    @ObservationIgnored var cameraChanged: (() -> Void)?

    /// From the map's delegate, every frame the visible region changes.
    func cameraDidChange() {
        cameraVersion &+= 1
        cameraChanged?()
    }

    /// How much of the honeycomb to show: fades in as you drag and out after.
    func honeycomb(at date: Date) -> Double {
        // `-alwaysHoneycomb YES` keeps it showing, for checking it in the simulator.
        if UserDefaults.standard.bool(forKey: "alwaysHoneycomb") { return 1 }
        let since = date.timeIntervalSince(draggingChangedAt)
        return isDragging ? min(1, since / 0.15) : max(0, 1 - since / 0.6)
    }
}

/// The clouds over the map, and your position on top of them, since MapKit's own dot
/// would be hidden under them. Baked into a picture that Core Animation warps to
/// follow the map (`BakedCloudLayer`), unless launched with `-cloudRenderer live`.
struct CloudLayer: View {
    let field: CloudField
    /// Changes whenever the field does, to spot tiles that have just cleared.
    let key: String
    let handle: MapHandle
    /// Tiles uncovered on this walk, for the honeycomb.
    var walkTiles: Set<CloudField.Tile> = []

    static let revealTime = 1.6

    var body: some View {
        switch CloudRenderer.current {
        case .baked:
            BakedCloudLayer(field: field, key: key, handle: handle, walkTiles: walkTiles)
        case .live:
            LiveCloudLayer(field: field, key: key, handle: handle, walkTiles: walkTiles)
        }
    }
}

/// The clouds drawn on top of the map about 30 times a second so they can drift and
/// breathe, and every frame while the map moves. They follow the map by asking it
/// where the ground is on screen.
struct LiveCloudLayer: View {
    let field: CloudField
    let key: String
    let handle: MapHandle
    var walkTiles: Set<CloudField.Tile> = []
    /// The spyglass's ring and where you are. Off when this stands in for the baked
    /// clouds for a moment, which draw those themselves.
    var overlays = true

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: (key: String, field: CloudField)?
    /// Clouds over tiles that have just cleared, fading out as they drift apart.
    @State private var leaving: [CloudField.Puff] = []
    /// Mist over tiles just walked again, fading out with a sparkle.
    @State private var leavingMist: [CloudField.MistPatch] = []
    @State private var changedAt = Date.distantPast

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: handle.isMoving ? nil : 1.0 / 30)) { timeline in
                Canvas { context, size in
                    guard let map = handle.map, size.width > 0 else { return }
                    let now = timeline.date
                    let clock = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
                    let reveal = min(1, now.timeIntervalSince(changedAt) / CloudLayer.revealTime)
                    let projection = Projection(map: map)
                    let bounds = CGRect(origin: .zero, size: size)
                    CosmeticTrail(points: handle.route, style: model.equipped[.trail], projection: projection, bounds: bounds, clock: clock)
                        .draw(in: &context)
                    CloudPainter(
                        field: field, leaving: reveal < 1 ? leaving : [], leavingMist: reveal < 1 ? leavingMist : [], reveal: reveal,
                        fresh: Set(leaving.map(\.tile)), projection: projection,
                        bounds: bounds, clock: clock, theme: model.equipped[.clouds]
                    )
                    .draw(in: &context)
                }
            }
            .drawingGroup()
            TimelineView(.animation(minimumInterval: handle.isMoving ? nil : 1.0 / 30)) { timeline in
                Canvas { context, size in
                    guard let map = handle.map, size.width > 0 else { return }
                    let now = timeline.date
                    let clock = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
                    let projection = Projection(map: map)
                    let honeycomb = handle.honeycomb(at: now)
                    if honeycomb > 0 {
                        HoneycombScene(field: field, walkTiles: walkTiles, projection: projection, bounds: CGRect(origin: .zero, size: size))
                            .draw(in: &context, opacity: honeycomb)
                    }
                    guard overlays else { return }
                    // Read inside the timeline so a ring expires even while the map is idle.
                    if let ring = model.activeSpyglassRing {
                        SpyglassRing(ring: ring, projection: projection).draw(in: &context)
                    }
                    if let location = map.userLocation.location {
                        YouAreHere(marker: model.equipped[.marker], location: location, projection: projection, clock: clock).draw(in: &context)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { shown = (key, field) }
        .onChange(of: key) {
            // Only animate tiles clearing, not a whole place being added or removed.
            if let old = shown, old.field.places == field.places {
                let still = Set(field.puffs.map(\.tile))
                leaving = old.field.puffs.filter { !still.contains($0.tile) }
                leavingMist = CloudField.clearedMist(from: old.field, to: field)
                changedAt = .now
            } else {
                leaving = []
                leavingMist = []
            }
            shown = (key, field)
        }
    }
}

/// Where you are: an orange dot in a white ring with a slow pulse, like the walk's
/// route line, drawn over the clouds.
private struct YouAreHere {
    var marker = "marker.dot"
    let location: CLLocation
    let projection: Projection
    let clock: Double

    func draw(in context: inout GraphicsContext) {
        guard projection.isInFront(MKMapPoint(location.coordinate)) else { return }
        let centre = projection.point(MKMapPoint(location.coordinate))
        let orange = Color.walkiesOrange

        // How sure the GPS is, as a faint patch on the ground.
        let accuracy = location.horizontalAccuracy * MKMapPointsPerMeterAtLatitude(location.coordinate.latitude)
        if location.horizontalAccuracy > 0 {
            let patch = projection.ellipse(centre: MKMapPoint(location.coordinate), radius: accuracy)
            if patch.width > 30 {
                context.fill(Path(ellipseIn: patch), with: .color(orange.opacity(0.12)))
            }
        }

        let pulse = (clock / 2).truncatingRemainder(dividingBy: 1)
        let ring = 11 + 22 * pulse
        context.stroke(
            Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2)),
            with: .color(orange.opacity(0.55 * (1 - pulse))), lineWidth: 3
        )

        var dot = context
        dot.addFilter(.shadow(color: .black.opacity(0.3), radius: 4, y: 2))
        dot.fill(Path(ellipseIn: CGRect(x: centre.x - 11, y: centre.y - 11, width: 22, height: 22)), with: .color(.white))
        if let asset = CosmeticArt.marker(marker) {
            var art = context
            art.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, y: 2))
            let image = art.resolve(Image(asset))
            let scale = 34 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            art.draw(image, in: CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2 - 3, width: size.width, height: size.height))
            return
        }
        context.fill(Path(ellipseIn: CGRect(x: centre.x - 7.5, y: centre.y - 7.5, width: 15, height: 15)), with: .color(orange))
    }
}

/// Keeps every trail readable over satellite pictures (grass, trees, water, roads):
/// a soft light halo, then a thin dark edge, under each look's own colours, like the
/// route lines in map apps. CloudPainter.kt has the same.
nonisolated enum TrailContrast {
    /// The plain line, brighter and bluer than it was so it doesn't sink into grass and water.
    static let teal = SceneColour(red: 0.1, green: 0.85, blue: 0.95)
    /// This walk's line, in points.
    static let width = 5.5
    static let halo = SceneColour.white
    static let haloAlpha = 0.45
    /// How much wider than the line the halo is, in all.
    static let haloExtra = 6.0
    static let edge = SceneColour(red: 0.05, green: 0.12, blue: 0.16)
    static let edgeAlpha = 0.6
    static let edgeExtra = 2.5
    /// The rainbow's colours: SwiftUI's, but a brighter, yellower green that grass can't swallow.
    static let rainbow: [SceneColour] = [
        SceneColour(red: 1, green: 0.23, blue: 0.19), SceneColour(red: 1, green: 0.58, blue: 0),
        SceneColour(red: 1, green: 0.8, blue: 0), SceneColour(red: 0.45, green: 0.93, blue: 0.3),
        SceneColour(red: 0.2, green: 0.78, blue: 1), SceneColour(red: 0, green: 0.48, blue: 1),
        SceneColour(red: 0.69, green: 0.32, blue: 0.87),
    ]
    /// The footprints' green, lighter and stronger than the shop's picture of them.
    static let footprint = SceneColour(red: 0.56, green: 0.93, blue: 0.42)
    static let sparkle = SceneColour(red: 1, green: 0.81, blue: 0.25)

    /// The halo and edge under a line `width` points wide.
    static func underlay(_ path: Path, width: Double, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(halo.color(haloAlpha)), style: StrokeStyle(lineWidth: width + haloExtra, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(edge.color(edgeAlpha)), style: StrokeStyle(lineWidth: width + edgeExtra, lineCap: .round, lineJoin: .round))
    }

    static func underlay(_ path: CGPath, width: Double, in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (colour, extra) in [(halo.cg(haloAlpha), haloExtra), (edge.cg(edgeAlpha), edgeExtra)] {
            context.addPath(path)
            context.setStrokeColor(colour)
            context.setLineWidth(width + extra)
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// The plain teal line on the map itself, with the halo and edge under it.
nonisolated final class OutlinedRouteRenderer: MKPolylineRenderer {
    override init(overlay: any MKOverlay) {
        super.init(overlay: overlay)
        strokeColor = UIColor(cgColor: TrailContrast.teal.cg(1))
        lineWidth = TrailContrast.width
        lineCap = .round
        lineJoin = .round
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if path == nil { createPath() }
        // Line widths here are in points, so they're scaled like MapKit scales its own.
        if let path { TrailContrast.underlay(path, width: lineWidth / zoomScale, in: context) }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

/// Decorative routes share the cloud projection, keeping stamps a fixed size on
/// screen and allowing the existing 30 Hz timeline to twinkle the sparkles.
struct CosmeticTrail {
    let points: [MKMapPoint]
    let style: String
    let projection: Projection
    let bounds: CGRect
    let clock: Double

    func draw(in context: inout GraphicsContext) {
        guard style == "trail.footprints" || style == "trail.sparkles" || style == "trail.rainbow", points.count > 1 else { return }
        let visible = bounds.insetBy(dx: -16, dy: -16)
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        for i in points.indices.dropFirst() {
            guard let (a, b) = projection.segment(points[i - 1], points[i]) else {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            if run.last != a {
                if !run.isEmpty { runs.append(run) }
                run = [a]
            }
            run.append(b)
        }
        if !run.isEmpty { runs.append(run) }

        if style == "trail.rainbow" {
            var path = Path()
            for run in runs {
                for i in run.indices.dropFirst() {
                    let a = run[i - 1], b = run[i]
                    guard let range = TrailLayout.visibleRange(from: a, to: b, in: visible) else { continue }
                    func at(_ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
                    let start = at(range.lowerBound)
                    if path.currentPoint != start { path.move(to: start) }
                    path.addLine(to: at(range.upperBound))
                }
            }
            // One gradient stroke keeps even a long route cheap to paint. Use its
            // longest screen axis so a north/south or diagonal walk gets every colour.
            let extent = path.boundingRect
            guard !extent.isNull, max(extent.width, extent.height) > 0 else { return }
            let horizontal = extent.width >= extent.height
            TrailContrast.underlay(path, width: TrailContrast.width, in: &context)
            context.stroke(path, with: .linearGradient(
                Gradient(colors: TrailContrast.rainbow.map { $0.color(1) }),
                startPoint: CGPoint(x: extent.minX, y: extent.minY),
                endPoint: horizontal ? CGPoint(x: extent.maxX, y: extent.minY) : CGPoint(x: extent.minX, y: extent.maxY)
            ), style: StrokeStyle(lineWidth: TrailContrast.width, lineCap: .round, lineJoin: .round))
            return
        }

        // Each print as a silhouette: a light halo, a dark edge, then the print itself
        // in a stronger green than the picture's.
        let template = Image("progress-footprint").renderingMode(.template)
        var footprint = context.resolve(template)
        footprint.shading = .color(TrailContrast.footprint.color(1))
        var edge = context.resolve(template)
        edge.shading = .color(TrailContrast.edge.color(TrailContrast.edgeAlpha))
        var halo = context.resolve(template)
        halo.shading = .color(TrailContrast.halo.color(TrailContrast.haloAlpha + 0.15))
        let print = CGRect(x: -4, y: -5.75, width: 8, height: 11.5)
        for run in runs {
            let stamps = TrailLayout.stamps(along: run, spacing: style == "trail.footprints" ? 12 : 26, in: visible)
            for stamp in stamps {
                var mark = context
                mark.translateBy(x: stamp.point.x, y: stamp.point.y)
                mark.rotate(by: .radians(stamp.angle))
                if style == "trail.footprints" {
                    mark.translateBy(x: 0, y: stamp.isLeft ? -2.5 : 2.5)
                    // The toes in the asset point up. Turn them forwards, then mirror
                    // alternate prints to make a left and right foot.
                    mark.rotate(by: .degrees(90))
                    if !stamp.isLeft { mark.scaleBy(x: -1, y: 1) }
                    mark.draw(halo, in: print.insetBy(dx: -2.2, dy: -2.2))
                    mark.draw(edge, in: print.insetBy(dx: -1, dy: -1))
                    mark.draw(footprint, in: print)
                } else {
                    let twinkle = 0.5 + 0.5 * sin(clock * 2.4 + Double(stamp.index) * 2.399)
                    let radius = 2 + twinkle * 1.8
                    var star = Path()
                    star.addLines([
                        CGPoint(x: 0, y: -radius), CGPoint(x: radius * 0.3, y: -radius * 0.3),
                        CGPoint(x: radius, y: 0), CGPoint(x: radius * 0.3, y: radius * 0.3),
                        CGPoint(x: 0, y: radius), CGPoint(x: -radius * 0.3, y: radius * 0.3),
                        CGPoint(x: -radius, y: 0), CGPoint(x: -radius * 0.3, y: -radius * 0.3)
                    ])
                    star.closeSubpath()
                    let alpha = 0.5 + twinkle * 0.5
                    mark.stroke(star, with: .color(TrailContrast.halo.color(TrailContrast.haloAlpha * alpha)), style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
                    mark.stroke(star, with: .color(TrailContrast.edge.color(TrailContrast.edgeAlpha * alpha)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    mark.fill(star, with: .color(TrailContrast.sparkle.color(alpha)))
                }
            }
        }
    }
}

struct SpyglassRing {
    let ring: Progression.Ring
    let projection: Projection

    func draw(in context: inout GraphicsContext) {
        let centre = MKMapPoint(ring.centre.cl)
        let radius = ring.radius * MKMapPointsPerMeterAtLatitude(ring.centre.lat)
        // Project the circumference itself so camera heading and perspective both
        // affect the ground ring, rather than drawing an axis-aligned screen oval.
        let circle = (0..<96).map { i in
            let angle = Double(i) / 96 * 2 * .pi
            return MKMapPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
        }
        let gold = Color(red: 1, green: 0.79, blue: 0.3)
        let polygon = projection.polygon(circle)
        guard polygon.count > 2 else { return }
        var fill = Path()
        fill.addLines(polygon)
        fill.closeSubpath()
        context.fill(fill, with: .color(gold.opacity(0.09)))
        var edge = Path()
        for i in circle.indices {
            guard let (a, b) = projection.segment(circle[i], circle[(i + 1) % circle.count]) else { continue }
            if edge.currentPoint != a { edge.move(to: a) }
            edge.addLine(to: b)
        }
        var glow = context
        glow.addFilter(.shadow(color: gold.opacity(0.5), radius: 4))
        glow.stroke(edge, with: .color(gold.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
        let anchor = circle[12]
        if projection.isInFront(anchor) {
            let point = projection.point(anchor)
            glow.draw(Image("progress-spyglass"), in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
        }
    }
}

private struct CloudPainter {
    let scene: CloudScene
    let theme: String

    init(
        field: CloudField, leaving: [CloudField.Puff], leavingMist: [CloudField.MistPatch], reveal: Double, fresh: Set<CloudField.Tile>,
        projection: Projection, bounds: CGRect, clock: Double, theme: String
    ) {
        scene = CloudScene(
            field: field, leaving: leaving, leavingMist: leavingMist, reveal: reveal, fresh: fresh,
            projection: projection, bounds: bounds, clock: clock
        )
        self.theme = theme
    }

    func draw(in context: inout GraphicsContext) {
        guard !scene.isEmpty else { return }
        let sprites = CloudSprites.sprites(for: theme)
        defer { drawMist(in: &context, sprites: sprites) }
        guard !scene.placed.isEmpty else { return }
        let tops = sprites.tops.map { context.resolve(Image(decorative: $0, scale: 1)) }
        let eraser = context.resolve(Image(decorative: sprites.eraser, scale: 1))
        let detail = scene.detail

        // Shadows on the ground, with the sun to the north-west. Straight onto the
        // map rather than through a layer of their own: a layer costs a whole extra
        // screen of drawing every frame, which the phone feels when zoomed in.
        if detail > 0 {
            let shadows = sprites.shadows.map { context.resolve(Image(decorative: $0, scale: 1)) }
            for p in scene.placed {
                context.opacity = 0.35 * p.fade * detail
                let r = p.rect
                context.draw(shadows[p.variant], in: r.offsetBy(dx: r.width * 0.15, dy: r.height * 0.18))
            }
            context.opacity = 1
        }

        context.drawLayer { layer in
            // Every shaded underside first, then every sunlit top, so the middle of the
            // blanket is one continuous white and the grey only shows round its edges.
            if detail > 0 {
                let bases = sprites.bases.map { layer.resolve(Image(decorative: $0, scale: 1)) }
                for p in scene.placed {
                    layer.opacity = p.fade * detail
                    layer.draw(bases[p.variant], in: p.rect)
                }
            }
            for p in scene.placed {
                layer.opacity = p.fade
                layer.draw(tops[p.variant], in: p.top)
            }
            layer.opacity = 1
            if let grid = scene.grid {
                layer.stroke(
                    grid,
                    with: .color(CloudScene.gridColour.color(0.5 * scene.gridFade)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4])
                )
            }
            if let clip = scene.roadClip {
                layer.clip(to: clip)
                for road in scene.roads {
                    let style = CloudScene.roadStyle(road.kind)
                    layer.stroke(
                        road.path,
                        with: .color(CloudScene.roadColour.color(style.alpha)),
                        style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dash)
                    )
                }
            }

            // Soft holes over walked tiles. New ones open up rather than just appearing.
            layer.blendMode = .destinationOut
            for rect in scene.erasers {
                layer.draw(eraser, in: rect)
            }
        }
    }

    /// The haze over misty tiles, on its own layer so where patches overlap it stays
    /// one even wash, then the sparkles over mist just cleared.
    private func drawMist(in context: inout GraphicsContext, sprites: CloudSprites) {
        if !scene.mist.isEmpty {
            let mist = context.resolve(Image(decorative: sprites.mist, scale: 1))
            var wash = context
            wash.opacity = CloudScene.mistOpacity
            wash.drawLayer { layer in
                for patch in scene.mist {
                    layer.opacity = patch.fade
                    layer.draw(mist, in: patch.rect)
                }
            }
        }
        for sparkle in scene.sparkles {
            let path = Path(CloudScene.star(sparkle))
            context.stroke(path, with: .color(.black.opacity(0.35 * sparkle.alpha)), lineWidth: 1)
            context.fill(path, with: .color(CloudScene.sparkleColour.color(sparkle.alpha)))
        }
    }
}

/// A handful of cumulus puffs drawn once at launch. Each is a few big soft circles,
/// split into a blue-grey underside and a sunlit white top nudged towards the
/// north-west. Also a blurred silhouette of each for its shadow, and a soft eraser.
nonisolated final class CloudSprites: @unchecked Sendable {
    static let count = 8
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var themes: [String: CloudSprites] = [:]
    }
    private static let cache = Cache()

    static func sprites(for theme: String) -> CloudSprites {
        let key = ["clouds.sunset", "clouds.storm", "clouds.candy"].contains(theme) ? theme : "clouds.classic"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let sprites = cache.themes[key] { return sprites }
        let sprites = CloudSprites(theme: key)
        cache.themes[key] = sprites
        return sprites
    }

    let bases: [CGImage]
    let tops: [CGImage]
    let shadows: [CGImage]
    let eraser: CGImage
    /// A soft pale disc for the mist, the same for every look.
    let mist: CGImage

    private init(theme: String) {
        let palette = Self.palette(theme)
        var bases: [CGImage] = []
        var tops: [CGImage] = []
        var shadows: [CGImage] = []
        for i in 0..<Self.count {
            let circles = Self.circles(seed: UInt64(i + 1))
            bases.append(Self.base(circles, size: 384, shade: palette.underside))
            tops.append(Self.top(circles, size: 384, centre: i.isMultiple(of: 2) ? palette.top : palette.alternate, edge: palette.edge))
            shadows.append(Self.shadow(circles, size: 160))
        }
        self.bases = bases
        self.tops = tops
        self.shadows = shadows
        eraser = Self.eraser(size: 128)
        mist = Self.mist(size: 128)
    }

    private init(bases: [CGImage], tops: [CGImage], shadows: [CGImage], eraser: CGImage, mist: CGImage) {
        self.bases = bases
        self.tops = tops
        self.shadows = shadows
        self.eraser = eraser
        self.mist = mist
    }

    /// The tops, eraser and mist shrunk to `pixels` across, for stamping thousands of
    /// tiny puffs (the overview): drawn from the full-size sprites, Core Graphics reads
    /// every pixel of them for every puff, however small. The undersides and shadows,
    /// which tiny puffs don't draw, are left as they are.
    func shrunk(to pixels: Int) -> CloudSprites {
        let size = max(2, min(pixels, 384))
        func shrink(_ image: CGImage) -> CGImage {
            let context = Self.bitmap(size)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return context.makeImage() ?? image
        }
        return CloudSprites(bases: bases, tops: tops.map(shrink), shadows: shadows, eraser: shrink(eraser), mist: shrink(mist))
    }

    private static func palette(_ theme: String) -> (top: CGColor, alternate: CGColor, edge: CGColor, underside: CGColor) {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
        switch theme {
        case "clouds.sunset":
            return (rgb(1, 0.86, 0.74), rgb(1, 0.78, 0.84), rgb(0.96, 0.73, 0.8), rgb(0.66, 0.57, 0.79))
        case "clouds.storm":
            return (rgb(0.69, 0.75, 0.83), rgb(0.69, 0.75, 0.83), rgb(0.54, 0.62, 0.73), rgb(0.32, 0.39, 0.51))
        case "clouds.candy":
            return (rgb(1, 0.82, 0.92), rgb(0.78, 0.9, 1), rgb(0.84, 0.79, 0.94), rgb(0.65, 0.68, 0.85))
        default:
            return (rgb(1, 1, 1), rgb(1, 1, 1), rgb(0.93, 0.945, 0.97), rgb(0.76, 0.8, 0.87))
        }
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

    private static func base(_ circles: [SIMD3<Double>], size: Int, shade: CGColor) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        fill(circles, in: context, size: s, scale: 1, shift: SIMD2(0, 0), colours: [shade, shade, shade.copy(alpha: 0)!], hardness: 0.65)
        return blur(context.makeImage()!, sigma: s * 0.01)
    }

    /// A touch greyer towards the edge, so overlapping tops leave faint billows.
    private static func top(_ circles: [SIMD3<Double>], size: Int, centre: CGColor, edge: CGColor) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        fill(
            circles, in: context, size: s, scale: 0.84, shift: SIMD2(-0.05, 0.06),
            colours: [centre, edge, edge.copy(alpha: 0)!], hardness: 0.5
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

    /// Morning haze: a pale blue-white, even across the middle and fading out over the
    /// outer half.
    private static func mist(size: Int) -> CGImage {
        let context = bitmap(size)
        let s = Double(size)
        let centre = CGPoint(x: s / 2, y: s / 2)
        let haze = CloudScene.mistColour
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [haze.cg(1), haze.cg(1), haze.cg(0)] as CFArray,
            locations: [0, 0.5, 1]
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

