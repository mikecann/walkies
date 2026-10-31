import MapKit

/// The clouds over the rest of the world: everywhere outside your places, so the
/// whole globe starts under cloud and you uncover it by walking. A map overlay, so
/// MapKit draws it a tile at a time, keeps it in step with the camera and picks
/// coarser tiles further off, which the puffs follow (`WorldCloudLayout`). Your
/// places are cut out of it, as `CloudLayer` draws their own clouds, streets and
/// progress over the top, and every world tile a walk has been through is cleared,
/// including ones that never become a place (a beach, a national park).
final class WorldClouds: NSObject, MKOverlay {
    nonisolated let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    nonisolated let boundingMapRect = MKMapRect.world

    private var places: [Boundary] = []
    private var holes: [WorldCloudLayout.Ring] = []
    private var walked: Set<Hex> = []
    private var buckets: [Int64: [MKMapPoint]] = [:]
    private var theme: String?
    /// Made when the map first asks for it, then kept up to date.
    private var made: WorldCloudsRenderer?

    var renderer: WorldCloudsRenderer {
        if let made { return made }
        let renderer = WorldCloudsRenderer(overlay: self)
        renderer.set(holes: holes)
        renderer.set(walked: buckets, theme: theme ?? "clouds.classic")
        made = renderer
        return renderer
    }

    /// Your places' outlines, cut out of the clouds.
    func update(places: [Boundary]) {
        guard places != self.places else { return }
        self.places = places
        holes = WorldCloudLayout.rings(places)
        made?.set(holes: holes)
        made?.setNeedsDisplay()
    }

    /// The world tiles walked, cleared, and the look the clouds are in.
    func update(walked: Set<Hex>, theme: String) {
        let changedLook = theme != self.theme
        let changed = walked.symmetricDifference(self.walked)
        guard changedLook || !changed.isEmpty else { return }
        self.walked = walked
        self.theme = theme
        buckets = WorldCloudLayout.buckets(walked)
        guard let made else { return }
        made.set(walked: buckets, theme: theme)
        // A walk adds a tile or two at a time, so only redraw round those.
        if changedLook || changed.count > 64 {
            made.setNeedsDisplay()
        } else {
            for hex in changed { made.setNeedsDisplay(WorldCloudLayout.reach(of: hex)) }
        }
    }
}

/// Draws `WorldClouds`, on MapKit's own threads, so what it draws from is swapped
/// in whole under a lock.
nonisolated final class WorldCloudsRenderer: MKOverlayRenderer, @unchecked Sendable {
    private struct Snapshot {
        var holes: [WorldCloudLayout.Ring] = []
        var walked: [Int64: [MKMapPoint]] = [:]
        var theme = "clouds.classic"
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    func set(holes: [WorldCloudLayout.Ring]) {
        lock.withLock { snapshot.holes = holes }
    }

    func set(walked: [Int64: [MKMapPoint]], theme: String) {
        lock.withLock {
            snapshot.walked = walked
            snapshot.theme = theme
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let now = lock.withLock { snapshot }
        let puffs = WorldCloudLayout.puffs(in: mapRect, zoomScale: Double(zoomScale))
        guard !puffs.isEmpty else { return }
        let sprites = CloudSprites.sprites(for: now.theme)

        // Only where none of your places are: the tile with each place over it as a
        // hole, even-odd, so a hole in a place (an enclave) is clouded again.
        let near = mapRect.insetBy(dx: -mapRect.size.width * 0.1, dy: -mapRect.size.height * 0.1)
        let over = now.holes.filter { $0.box.intersects(near) }
        if !over.isEmpty {
            let clip = CGMutablePath()
            clip.addRect(rect(for: near))
            for ring in over { clip.addLines(between: ring.points.map { point(for: $0) }); clip.closeSubpath() }
            context.addPath(clip)
            context.clip(using: .evenOdd)
        }

        // As the places' clouds are drawn (CloudScene): shadows on the ground, then every
        // underside, then every top, so the blanket is one white with grey round its edges.
        context.setAlpha(0.35)
        for puff in puffs {
            let r = rect(for: puff.box)
            CloudScene.draw(sprites.shadows[puff.variant], in: r.offsetBy(dx: r.width * 0.15, dy: r.height * 0.18), on: context)
        }
        context.setAlpha(1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for puff in puffs { CloudScene.draw(sprites.bases[puff.variant], in: rect(for: puff.box), on: context) }
        for puff in puffs { CloudScene.draw(sprites.tops[puff.variant], in: rect(for: puff.box), on: context) }
        context.setBlendMode(.destinationOut)
        let radius = WorldCloudLayout.clearing
        for centre in WorldCloudLayout.walked(near: near, in: now.walked) {
            let hole = MKMapRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            CloudScene.draw(sprites.eraser, in: rect(for: hole), on: context)
        }
        context.endTransparencyLayer()
    }
}

/// Where the world's clouds go, worked out from map points alone so every tile at a
/// zoom agrees on them and they don't move as you pan.
nonisolated enum WorldCloudLayout {
    struct Ring: Sendable {
        var points: [MKMapPoint]
        var box: MKMapRect
    }

    struct Puff {
        var centre: MKMapPoint
        var box: MKMapRect
        var variant: Int
    }

    /// A world tile's size, centre to corner, in map points. The world grid's tiles are
    /// the same size in map points everywhere (their ground size changes by latitude).
    static let hexSize = HexGrid.world.size * MKMapSize.world.width / (2 * .pi * WorldProjection.radius)
    /// The hole over a walked tile, as the places' clouds cut it (`CloudField.clearing`).
    static let clearing = hexSize * CloudField.clearing
    /// Closest together the puffs get: one a tile, as in your places, so zoomed in the
    /// two blankets look the same.
    static let closest = hexSize * 3.squareRoot()
    /// Further out, puffs double in spacing until they're at least this many points apart
    /// on screen, so a map tile never has more than a few hundred to draw.
    static let screenSpacing = 20.0
    /// Puff radius as a share of their spacing: a bit more than the places' (`CloudField.spread`
    /// over a tile's spacing), as nothing round them is ever clear, so no gaps show between.
    static let spread = CloudField.spread / 3.squareRoot() * 1.2
    /// How far a puff is nudged off its spot, as a share of the spacing, so the blanket
    /// doesn't sit on an obvious honeycomb.
    static let jitter = 0.3
    /// Walked tiles are kept in squares this big (map points), to find the ones near a map tile.
    static let bucket = 16_384.0

    /// The spacing at this zoom: the closest, doubled until it's far enough apart on screen.
    static func spacing(zoomScale: Double) -> (level: Int, spacing: Double) {
        var level = 0
        var spacing = closest
        while spacing * zoomScale < screenSpacing, spacing < MKMapSize.world.width {
            spacing *= 2
            level += 1
        }
        return (level, spacing)
    }

    /// Every puff that reaches into `rect`, north first so further south sits in front.
    /// Hex rows `spacing` apart along them, each nudged and sized the same way every time.
    static func puffs(in rect: MKMapRect, zoomScale: Double) -> [Puff] {
        let (level, spacing) = spacing(zoomScale: zoomScale)
        let rowHeight = spacing * 3.squareRoot() / 2
        let reach = spacing * spread * 1.3 + spacing * jitter / 2
        let world = MKMapSize.world.width
        let firstRow = Int(((rect.minY - reach) / rowHeight).rounded(.down))
        let lastRow = Int(((rect.maxY + reach) / rowHeight).rounded(.up))
        var out: [Puff] = []
        for row in firstRow...lastRow {
            let y = Double(row) * rowHeight
            guard y >= -reach, y <= world + reach else { continue }
            let shift = row.isMultiple(of: 2) ? 0 : spacing / 2
            let firstColumn = Int(((rect.minX - reach - shift) / spacing).rounded(.down))
            let lastColumn = Int(((rect.maxX + reach - shift) / spacing).rounded(.up))
            for column in firstColumn...lastColumn {
                var rng = SplitMix64(seed: seed(level: level, row: row, column: column))
                let centre = MKMapPoint(
                    x: Double(column) * spacing + shift + (rng.unit() - 0.5) * jitter * spacing,
                    y: y + (rng.unit() - 0.5) * jitter * spacing
                )
                let radius = spacing * spread * (0.88 + rng.unit() * 0.35)
                let box = MKMapRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                guard box.intersects(rect) else { continue }
                out.append(Puff(centre: centre, box: box, variant: Int(rng.next() % UInt64(CloudSprites.count))))
            }
        }
        return out.sorted { $0.centre.y < $1.centre.y }
    }

    static func seed(level: Int, row: Int, column: Int) -> UInt64 {
        UInt64(bitPattern: Int64((level &* 2_654_435_761) ^ (row &* 73_856_093) ^ (column &* 19_349_663)))
    }

    /// The places' outlines and holes as map-point rings, each with its box.
    static func rings(_ places: [Boundary]) -> [Ring] {
        places.flatMap { $0.polygons }.flatMap { [$0.outer] + $0.holes }.compactMap { ring in
            let points = ring.map { MKMapPoint($0.cl) }
            guard points.count > 2 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            let box = MKMapRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return Ring(points: points, box: box)
        }
    }

    /// Walked tiles' centres, by the square they're in.
    static func buckets(_ walked: Set<Hex>) -> [Int64: [MKMapPoint]] {
        var out: [Int64: [MKMapPoint]] = [:]
        for hex in walked {
            let centre = centre(of: hex)
            out[key(Int64((centre.x / bucket).rounded(.down)), Int64((centre.y / bucket).rounded(.down))), default: []].append(centre)
        }
        return out
    }

    /// Walked tiles whose hole reaches into `rect`.
    static func walked(near rect: MKMapRect, in buckets: [Int64: [MKMapPoint]]) -> [MKMapPoint] {
        let area = rect.insetBy(dx: -clearing, dy: -clearing)
        let columns = Int64((area.minX / bucket).rounded(.down))...Int64((area.maxX / bucket).rounded(.down))
        let rows = Int64((area.minY / bucket).rounded(.down))...Int64((area.maxY / bucket).rounded(.down))
        // Zoomed right out a map tile can cover thousands of squares: go through the tiles instead.
        if columns.count * rows.count > buckets.count {
            return buckets.values.flatMap { $0 }.filter { area.contains($0) }
        }
        var out: [MKMapPoint] = []
        for column in columns {
            for row in rows {
                for centre in buckets[key(column, row)] ?? [] where area.contains(centre) { out.append(centre) }
            }
        }
        return out
    }

    /// What needs drawing again when this tile is walked.
    static func reach(of hex: Hex) -> MKMapRect {
        let c = centre(of: hex)
        return MKMapRect(x: c.x - clearing, y: c.y - clearing, width: clearing * 2, height: clearing * 2)
    }

    static func centre(of hex: Hex) -> MKMapPoint {
        MKMapPoint(HexGrid.world.projection.unproject(HexGrid.world.centre(of: hex)).cl)
    }

    private static func key(_ column: Int64, _ row: Int64) -> Int64 { (column << 32) ^ (row & 0xFFFF_FFFF) }
}
