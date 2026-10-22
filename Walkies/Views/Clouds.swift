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

    /// Which places this covers, so the layer can tell tiles clearing from a place
    /// being added or removed.
    var places: [UUID] = []
    /// North first, so clouds further south sit in front of them.
    var puffs: [Puff] = []
    /// Where to cut the clouds away over walked hexes.
    var clearings: [Clearing] = []
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

    init(cities: [City]) {
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

    private static func hash(_ hex: Hex) -> Int {
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
                        field: field, leaving: reveal < 1 ? leaving : [], reveal: reveal,
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
                changedAt = .now
            } else {
                leaving = []
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
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple]),
                startPoint: CGPoint(x: extent.minX, y: extent.minY),
                endPoint: horizontal ? CGPoint(x: extent.maxX, y: extent.minY) : CGPoint(x: extent.minX, y: extent.maxY)
            ), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            return
        }

        let footprint = context.resolve(Image("progress-footprint"))
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
                    mark.draw(footprint, in: CGRect(x: -3.5, y: -5, width: 7, height: 10))
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
                    mark.fill(star, with: .color(Color(red: 1, green: 0.81, blue: 0.25).opacity(0.5 + twinkle * 0.5)))
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

    init(field: CloudField, leaving: [CloudField.Puff], reveal: Double, fresh: Set<CloudField.Tile>, projection: Projection, bounds: CGRect, clock: Double, theme: String) {
        scene = CloudScene(field: field, leaving: leaving, reveal: reveal, fresh: fresh, projection: projection, bounds: bounds, clock: clock)
        self.theme = theme
    }

    func draw(in context: inout GraphicsContext) {
        guard !scene.isEmpty else { return }
        let sprites = CloudSprites.sprites(for: theme)
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

