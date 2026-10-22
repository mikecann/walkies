import MapKit
import SwiftUI

/// The clouds, baked into a picture off the main thread and warped by Core Animation
/// to follow the map, so moving the map costs no drawing at all: each frame just sets
/// one layer's transform. See `BakedCloudEngine` for when it bakes again.
///
/// Still drawn every frame: a decorative trail you've equipped (footprints, sparkles
/// or rainbow) on this walk, and the spyglass's ring while one's out, in Canvases;
/// and for the 1.6 seconds that tiles take to clear, the clouds round them.
struct BakedCloudLayer: View {
    let field: CloudField
    let key: String
    let handle: MapHandle
    var walkTiles: Set<CloudField.Tile> = []

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = BakedCloudEngine()

    var body: some View {
        let trail = model.equipped[.trail]
        let inputs = BakedCloudEngine.Inputs(
            field: field, key: key, theme: model.equipped[.clouds], walkTiles: walkTiles,
            marker: model.equipped[.marker], reduceMotion: reduceMotion
        )
        ZStack {
            if engine.status.needsLive {
                // Nothing baked to show yet, a place added or a new look not baked yet,
                // or the camera's swung so far the bake's partly behind it: drawn live
                // for a moment rather than show the map bare.
                LiveCloudLayer(field: field, key: key, handle: handle, walkTiles: walkTiles, overlays: false)
            } else if CosmeticTrail.drawnOnCanvas(trail), model.activePath.count > 1 {
                TrailCanvas(handle: handle, style: trail, points: model.activePath.count, reduceMotion: reduceMotion)
            }
            LayerHost(layer: engine.cloudHost) { engine.update(inputs, handle: handle) }
            if model.activeSpyglassRing != nil {
                TimelineView(.animation(minimumInterval: handle.isMoving ? nil : 1.0 / 30)) { _ in
                    Canvas { context, size in
                        guard let map = handle.map, size.width > 0, let ring = model.activeSpyglassRing else { return }
                        SpyglassRing(ring: ring, projection: Projection(map: map)).draw(in: &context)
                    }
                }
            }
            LayerHost(layer: engine.markerHost)
        }
        .allowsHitTesting(false)
        .onAppear {
            engine.update(inputs, handle: handle)
            engine.start(handle: handle)
        }
        .onDisappear { engine.stop() }
    }
}

/// The equipped trail, under the clouds, for the trails the map can't draw itself.
private struct TrailCanvas: View {
    let handle: MapHandle
    let style: String
    /// How long the walk is, to draw it again as it grows while the map's still.
    let points: Int
    let reduceMotion: Bool

    var body: some View {
        // Only sparkles twinkle; the others only need redrawing as the map moves.
        let still = !handle.isMoving && (style != "trail.sparkles" || reduceMotion)
        TimelineView(.animation(minimumInterval: handle.isMoving ? nil : 1.0 / 30, paused: still)) { timeline in
            Canvas { context, size in
                guard let map = handle.map, size.width > 0 else { return }
                let clock = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                CosmeticTrail(points: handle.route, style: style, projection: Projection(map: map), bounds: CGRect(origin: .zero, size: size), clock: clock)
                    .draw(in: &context)
            }
        }
    }
}

/// Shows a layer, from the top left of a view that fills the map.
struct LayerHost: UIViewRepresentable {
    let layer: CALayer
    var update: () -> Void = {}

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.hosted = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        update()
    }

    /// Keeps the layer the size of the view, so nothing in it lies outside its host.
    final class HostView: UIView {
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer.addSublayer(hosted) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.anchorPoint = .zero
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// A layer that never animates by itself.
nonisolated final class PlainLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

nonisolated private final class PlainShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// Counts from the baked renderer, for the `-perfRun` harness.
final class CloudRenderStats {
    static let shared = CloudRenderStats()
    var bakes = 0
    var drafts = 0
    var bakeMilliseconds = 0.0
    var longestBake = 0.0
    /// Bakes given up on for taking too long.
    var abandoned = 0
    /// Updates (about one a frame) when the live Canvas stood in for want of a bake.
    var liveTicks = 0
    /// Updates when the overview stood in, or showed past the edge of a bake.
    var overviewTicks = 0
    var overviews = 0
    var overviewMilliseconds = 0.0
    /// Frames the clouds round tiles clearing were drawn.
    var revealFrames = 0
    /// When the map was first laid out, and when the overview or a bake first showed on it.
    var mapShownAt: Double?
    var firstCloudsAt: Double?

    var firstCloudsMilliseconds: Double? {
        guard let mapShownAt, let firstCloudsAt else { return nil }
        return (firstCloudsAt - mapShownAt) * 1000
    }
}

/// Keeps the baked clouds on the map. Each frame (driven by the map telling the
/// handle its camera changed, so in step with MapKit, and by a display link for the
/// rest) it measures the projection, sets the layers' transforms to warp the bake
/// onto it, and asks for a new bake if the one on screen needs it:
///
/// - new tiles or a new look: from the same camera and drift if they still fit, so
///   the new one drops straight in (and tiles clearing open up over it);
/// - while you move the map: a rough, wide bake only once the screen's half way into
///   the margin, or zoomed or turned well past, with the drift held;
/// - while MapKit flies the camera by itself (as it does on opening): none, as it'd
///   be far off by the time it was ready;
/// - once it's been still a quarter of a second: a sharp one from exactly there;
/// - still for 2.5 s: the same picture with the clouds drifted on, cross-faded in.
///
/// One bake at a time, on a background thread. One that's taking far longer than
/// they have been is given up on (see `BakePolicy.giveUp`), but still shown if it
/// turns up before a newer one. One for a camera that's since gone far off isn't
/// waited for once the camera's still again.
///
/// Under the bake, wherever it doesn't reach (or there isn't one fit to show yet),
/// the overview: every place's clouds from above, small, made once from the tiles
/// (and before the first bake). So the map's never bare.
///
/// While the camera moves, that's all: the bake on screen, warped however far it's
/// stretched (bar to a speck), over the overview however soft, as both cost nothing
/// a frame and the live Canvas costs a lot. Only once it's still, zoomed in where the
/// overview's too soft, and with no bake to show at all, does the live Canvas stand
/// in, for the moment until the sharp bake's done; or before there's an overview. A
/// bake that comes to cover the screen fades in over whichever it was, and the
/// overview then fades out.
final class BakedCloudEngine {
    struct Inputs {
        var field: CloudField
        var key: String
        var theme: String
        var walkTiles: Set<CloudField.Tile>
        var marker: String
        var reduceMotion: Bool
    }

    @Observable
    final class Status {
        /// No bake fit to show and the overview too soft here, so the live Canvas stands in.
        var needsLive = false
    }

    let status = Status()

    /// SwiftUI makes a new engine every time the view's rebuilt and keeps only the
    /// first, so the layers are only made once one's used.
    private final class Layers {
        let cloudHost = PlainLayer()
        let markerHost = PlainLayer()
        /// The overview's window, warped onto the screen, under the bake.
        let overviewRoot = PlainLayer()
        let overviewImage = PlainLayer()
        /// The bake's box, warped onto the screen.
        let cloudRoot = PlainLayer()
        let cloudImage = PlainLayer()
        /// The clouds round tiles clearing, drawn each frame over a hole in `cloudImage`.
        let patchLayer = PlainLayer()
        let honeycombRoot = PlainLayer()
        let marker = MarkerLayers()

        init() {
            for layer in [overviewRoot, cloudRoot, honeycombRoot] {
                layer.anchorPoint = .zero
                layer.position = .zero
                layer.isHidden = true
            }
            overviewRoot.masksToBounds = true
            overviewImage.anchorPoint = .zero
            overviewImage.position = .zero
            cloudImage.anchorPoint = .zero
            if LaunchArguments.has("-bakeOutline") {
                // `-bakeOutline`: a red edge round the bake, to see where it's warped to,
                // and a blue one round the bit of the overview that's showing.
                cloudImage.borderWidth = 3
                cloudImage.borderColor = UIColor.systemRed.cgColor
                overviewRoot.borderWidth = 3
                overviewRoot.borderColor = UIColor.systemBlue.cgColor
            }
            patchLayer.anchorPoint = .zero
            patchLayer.isHidden = true
            overviewRoot.addSublayer(overviewImage)
            cloudRoot.addSublayer(cloudImage)
            cloudRoot.addSublayer(patchLayer)
            cloudHost.addSublayer(overviewRoot)
            cloudHost.addSublayer(cloudRoot)
            cloudHost.addSublayer(honeycombRoot)
            markerHost.addSublayer(marker.accuracy)
            markerHost.addSublayer(marker.root)
        }
    }
    private lazy var layers = Layers()
    var cloudHost: CALayer { layers.cloudHost }
    var markerHost: CALayer { layers.markerHost }
    private var overviewRoot: CALayer { layers.overviewRoot }
    private var overviewImage: CALayer { layers.overviewImage }
    private var cloudRoot: CALayer { layers.cloudRoot }
    private var cloudImage: CALayer { layers.cloudImage }
    private var patchLayer: CALayer { layers.patchLayer }
    private var honeycombRoot: CALayer { layers.honeycombRoot }
    private var marker: MarkerLayers { layers.marker }

    private var handle: MapHandle?
    private var inputs: Inputs?
    private var walkKey = 0
    private var link: CADisplayLink?
    private var linkActive = true

    private(set) var front: CloudBake?
    private var honeycomb: (image: CGImage, frame: BakeFrame, walkKey: Int)?
    private var lastRequest: (frame: BakeFrame, honeycomb: Bool)?
    /// Every bake asked for is numbered, so one that turns up late can't replace a newer one.
    private var requests = 0
    private var frontRequest = 0
    /// The bake being made, what it's from, and when it was asked for.
    private var inFlight: (request: Int, frame: BakeFrame, asked: Double)?
    var baking: Bool { inFlight != nil }
    /// How long the last bake took, from asking to having it, to know when one's stuck.
    private var lastBakeSeconds: Double?
    /// Bakes given up on for taking too long, and ones not waited for as the camera had
    /// gone far from them.
    private(set) var abandoned = 0
    private(set) var superseded = 0

    /// Makes a bake, on a background thread. Tests stand in for it.
    var bakery: @Sendable (BakeJob) -> CloudBake = { CloudBakery.bake($0) }
    /// Notes what the engine asks for and gets, for tests to check the order of.
    var log: ((String) -> Void)?

    private(set) var overview: CloudOverview?
    private var overviewRequests = 0
    private var overviewAsked: (key: String, theme: String, at: Double)?
    /// The overview's pixel budget. Tests make it tiny, to have it too soft to show.
    var overviewPixels = CloudBakery.overviewPixels

    /// What's on screen, as of the last tick.
    private(set) var showingFront = false
    private(set) var showingOverview = false
    /// The front bake reaches past every edge of the screen.
    private var frontCovers = false
    private var frontFadeEnds = -Double.infinity
    /// The live Canvas stays under a bake fading in over it until then.
    private var liveHeldUntil = -Double.infinity
    /// The overview's fading out over a bake that's come to cover the screen, until then.
    private var overviewFadeEnds: Double?

    private struct Reveal {
        var started: Double
        var leaving: [CloudField.Puff]
        var leavingMist: [CloudField.MistPatch] = []
        var fresh: Set<CloudField.Tile>
        /// Worked out for the bake on screen: the box drawn live, and what's near it.
        var frameID: Int?
        var patch: CGRect?
        var area = CGRect.null
        var field = CloudField()
        var reference: CloudScene.Reference?
    }
    private var reveal: Reveal?

    private var projection: Projection?
    private var measuredAt = 0.0
    private var seenVersion = -1
    private var seenSize = CGSize.zero
    private var lastCameraChange = -Double.infinity

    func start(handle: MapHandle) {
        self.handle = handle
        handle.cameraChanged = { [weak self] in self?.tick() }
        guard link == nil else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.step))
        link.add(to: .main, forMode: .common)
        self.link = link
        linkActive = true
        tick()
    }

    func stop() {
        link?.invalidate()
        link = nil
        handle?.cameraChanged = nil
    }

    func update(_ inputs: Inputs, handle: MapHandle) {
        self.handle = handle
        if let old = self.inputs, old.walkTiles != inputs.walkTiles { walkKey += 1 }
        let changed = self.inputs.map { $0.key != inputs.key || $0.theme != inputs.theme || $0.marker != inputs.marker } ?? true
        self.inputs = inputs
        // Not straight away: this is called while SwiftUI's updating its views.
        if changed { DispatchQueue.main.async { [weak self] in self?.tick() } }
    }

    private final class LinkTarget: NSObject {
        weak var engine: BakedCloudEngine?
        init(_ engine: BakedCloudEngine) { self.engine = engine }
        @objc func step() { engine?.tick() }
    }

    // MARK: Each frame

    /// Stands in for the map in tests: its size, pixels per point, and where the ground is on it.
    var testScreen: (() -> (size: CGSize, displayScale: Double, projection: Projection))?

    func tick() {
        guard let handle, let inputs else { return }
        // Needs no camera, so it's started before the map's even laid out.
        askOverview(inputs)
        let map = handle.map
        let test = testScreen?()
        let size: CGSize, displayScale: Double
        if let test {
            (size, displayScale) = (test.size, test.displayScale)
        } else if let map {
            (size, displayScale) = (map.bounds.size, map.traitCollection.displayScale)
        } else {
            return
        }
        guard size.width > 0, size.height > 0 else { return }
        let now = CACurrentMediaTime()
        let stats = CloudRenderStats.shared
        if stats.mapShownAt == nil { stats.mapShownAt = now }
        let version = handle.cameraVersion
        var changed = version != seenVersion || size != seenSize
        // Measured afresh every tick (once a frame at most), not only when MapKit says
        // the camera's moved: it doesn't always (a camera set without animating, from
        // inside its own will-change callback, or the 3D ground loading in), and a bake
        // from a stale measurement is warped to where the map was, not where it is.
        if changed || projection == nil || now - measuredAt > 0.004 {
            let measured = test?.projection ?? map.map { Projection(map: $0) }
            if let old = projection, let measured, !old.matches(measured, size: size) { changed = true }
            projection = measured
            measuredAt = now
            seenVersion = version
            seenSize = size
        }
        if changed { lastCameraChange = now }
        guard let projection, projection.isValid else { return }
        let moving = handle.isMoving || now - lastCameraChange < BakePolicy.settle
        let clock = inputs.reduceMotion ? 0 : Date.timeIntervalSinceReferenceDate

        if let inFlight {
            if now - inFlight.asked > BakePolicy.giveUp(lastBake: lastBakeSeconds) {
                // Stop waiting, and ask again: for the same camera too, if it's still there.
                self.inFlight = nil
                lastRequest = nil
                abandoned += 1
                CloudRenderStats.shared.abandoned += 1
                log?("give up #\(inFlight.request)")
            } else if !moving, !(BakeWarp(now: projection, frame: inFlight.frame)?.shows(size: size, now: projection) ?? false) {
                // From a camera that's since gone far off (the map opening on you while
                // the first bake was being made): no use waiting for it once it's still.
                // It's left to finish, and dropped if a newer one's in by then.
                self.inFlight = nil
                superseded += 1
                log?("supersede #\(inFlight.request)")
            }
        }
        // The overview first, as it's what shows until the bake's done, and they'd only
        // slow each other down; but not for long, should it be slow.
        let awaitingOverview = front == nil && overview == nil && overviewAsked.map { now - $0.at < BakePolicy.overviewWait } ?? false
        if !baking, !awaitingOverview { ask(projection: projection, size: size, moving: moving, clock: clock, displayScale: displayScale) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let live = present(projection: projection, size: size, now: now, moving: moving)
        if let map { placeMarker(map: map, projection: projection, inputs: inputs) }
        CATransaction.commit()
        if status.needsLive != live { status.needsLive = live }
        if live { stats.liveTicks += 1 }
        if showingOverview, overviewFadeEnds == nil { stats.overviewTicks += 1 }
        if stats.firstCloudsAt == nil, showingFront || (showingOverview && !overviewRoot.isHidden) { stats.firstCloudsAt = now }

        // Every frame while anything's moving or fading; otherwise just often enough to
        // notice the drift's due. The map changing wakes it straight away.
        let fading = now < frontFadeEnds || overviewFadeEnds != nil || now < liveHeldUntil
        let busy = moving || handle.isDragging || handle.honeycomb(at: .now) > 0 || reveal != nil || fading
        if busy != linkActive, let link {
            linkActive = busy
            link.preferredFrameRateRange = busy ? .default : CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
        }
    }

    /// Puts the bake, the overview and the honeycomb on screen as they fit the camera
    /// now. True if the live Canvas has to stand in.
    private func present(projection: Projection, size: CGSize, now: Double, moving: Bool) -> Bool {
        guard let inputs else { return true }
        // The bake on screen, if it's of these places in this look and still shows
        // something like what's on screen: never warped off it, or to a speck.
        let warp = front.flatMap { front -> BakeWarp? in
            guard front.field.places == inputs.field.places, front.theme == inputs.theme,
                  let warp = BakeWarp(now: projection, frame: front.frame), warp.shows(size: size, now: projection, moving: moving)
            else { return nil }
            return warp
        }
        let covers = warp?.covers(size: size, now: projection) ?? false
        frontCovers = covers
        // The overview, if it's of these places (a new look can make do with the old
        // one for the moment it takes): however soft while the camera moves, and once
        // it's still, sharp enough here or under a bake that shows.
        let placement = overview.flatMap { overview -> OverviewPlacement? in
            guard overview.places == inputs.field.places, overview.image != nil else { return nil }
            return OverviewPlacement(overview: overview.projection, pixels: overview.pixels, now: projection, size: size)
        }
        let overviewFits = placement.map { moving || warp != nil || !$0.visible || $0.stretch <= BakePolicy.overviewStretch } ?? false
        // Never while moving, bar the moment before there's anything else at all.
        var live = !covers && !overviewFits && (!moving || warp == nil)

        if let front, let warp, !live {
            cloudRoot.transform = warp.layerTransform
            if !showingFront {
                // Over whatever stood in for it.
                cloudRoot.isHidden = false
                cloudRoot.removeAnimation(forKey: "fade")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = BakePolicy.fade
                cloudRoot.add(fade, forKey: "fade")
                frontFadeEnds = now + BakePolicy.fade
                if status.needsLive { liveHeldUntil = frontFadeEnds }
            }
            showingFront = true
            placeReveal(front: front, now: now)
        } else {
            cloudRoot.isHidden = true
            showingFront = false
        }
        if covers, now < liveHeldUntil { live = true }

        if let placement, overviewFits, !live, !covers || overviewFadeEnds != nil || showingOverview {
            if placement.visible {
                overviewRoot.bounds = CGRect(origin: .zero, size: placement.windowSize)
                overviewRoot.transform = placement.transform
                overviewImage.setAffineTransform(placement.imageTransform)
                overviewRoot.isHidden = false
            } else {
                overviewRoot.isHidden = true
            }
            if !covers {
                if overviewFadeEnds != nil || overviewRoot.opacity < 1 {
                    overviewRoot.removeAnimation(forKey: "fade")
                    overviewRoot.opacity = 1
                    overviewFadeEnds = nil
                }
                showingOverview = true
            } else if let ends = overviewFadeEnds {
                // Fading out over the bake that's come.
                if now >= ends { hideOverview() }
            } else {
                // Once the bake's faded in over it.
                let delay = max(0, frontFadeEnds - now)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.beginTime = CACurrentMediaTime() + delay
                fade.duration = BakePolicy.fade
                fade.fillMode = .backwards
                overviewRoot.opacity = 0
                overviewRoot.add(fade, forKey: "fade")
                overviewFadeEnds = now + delay + BakePolicy.fade
                showingOverview = true
            }
        } else {
            hideOverview()
        }

        // The honeycomb from its own bake, while you drag.
        let opacity = live ? 0 : handle?.honeycomb(at: .now) ?? 0
        if opacity > 0, let honeycomb, let warp = BakeWarp(now: projection, frame: honeycomb.frame), warp.shows(size: size, now: projection) {
            honeycombRoot.transform = warp.layerTransform
            honeycombRoot.opacity = Float(opacity)
            honeycombRoot.isHidden = false
        } else {
            honeycombRoot.isHidden = true
        }
        return live
    }

    private func hideOverview() {
        overviewRoot.isHidden = true
        overviewRoot.removeAnimation(forKey: "fade")
        overviewRoot.opacity = 1
        overviewFadeEnds = nil
        showingOverview = false
    }

    /// Tiles clearing: the bake everywhere but round them, and there the clouds drawn
    /// live as they part, from the bake's own camera, drift and pixels, so the two meet
    /// without a seam.
    private func placeReveal(front: CloudBake, now: Double) {
        guard var reveal else { return }
        let progress = (now - reveal.started) / CloudLayer.revealTime
        if progress >= 1 {
            self.reveal = nil
            cloudImage.mask = nil
            patchLayer.isHidden = true
            patchLayer.contents = nil
            return
        }
        let frame = front.frame
        if reveal.frameID != frame.id {
            reveal.frameID = frame.id
            reveal.patch = CloudBakery.revealPatch(field: front.field, leaving: reveal.leaving, leavingMist: reveal.leavingMist, frame: frame)
            if let patch = reveal.patch {
                // Big enough round the patch to take in every puff, street and grid
                // line that reaches into it.
                reveal.area = patch.insetBy(dx: -patch.width, dy: -patch.height)
                reveal.field = CloudBakery.near(reveal.area, in: front.field, projection: frame.projection)
                reveal.reference = CloudScene.Reference(front.field)
                let local = patch.offsetBy(dx: -frame.rect.minX, dy: -frame.rect.minY)
                let mask = PlainShapeLayer()
                mask.frame = CGRect(origin: .zero, size: frame.rect.size)
                let path = CGMutablePath()
                path.addRect(mask.bounds)
                path.addRect(local)
                mask.path = path
                mask.fillRule = .evenOdd
                mask.fillColor = UIColor.black.cgColor
                cloudImage.mask = mask
                patchLayer.frame = local
            } else {
                cloudImage.mask = nil
                patchLayer.isHidden = true
            }
            self.reveal = reveal
        }
        guard let patch = reveal.patch else { return }
        let scene = CloudScene(
            field: reveal.field, leaving: reveal.leaving, leavingMist: reveal.leavingMist, reveal: progress, fresh: reveal.fresh,
            projection: frame.projection, bounds: reveal.area, clock: front.clock, puffMargin: 0, reference: reveal.reference
        )
        let sprites = CloudSprites.sprites(for: front.theme)
        patchLayer.contents = CloudBakery.render(patch, scale: frame.scale) { scene.draw(in: $0, sprites: sprites) }
        patchLayer.isHidden = false
        CloudRenderStats.shared.revealFrames += 1
    }

    // MARK: Baking

    /// The overview, once for each set of tiles and look, on a thread of its own so it
    /// never waits behind a bake, and behind the main thread and MapKit: it only takes
    /// a moment, and the first bake waits for it (see `BakePolicy.overviewWait`).
    private func askOverview(_ inputs: Inputs) {
        if let overview, overview.fieldKey == inputs.key, overview.theme == inputs.theme { return }
        if let asked = overviewAsked, asked.key == inputs.key, asked.theme == inputs.theme { return }
        overviewAsked = (inputs.key, inputs.theme, CACurrentMediaTime())
        overviewRequests += 1
        let id = overviewRequests
        let (field, key, theme, pixels) = (inputs.field, inputs.key, inputs.theme, overviewPixels)
        let clock = inputs.reduceMotion ? 0 : Date.timeIntervalSinceReferenceDate
        log?("ask overview #\(id)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let overview = CloudBakery.overview(field: field, fieldKey: key, theme: theme, clock: clock, pixels: pixels)
            DispatchQueue.main.async { self?.accept(overview, request: id) }
        }
    }

    private var overviewRequest = 0

    private func accept(_ overview: CloudOverview, request: Int) {
        guard request > overviewRequest else { return }
        overviewRequest = request
        if request == overviewRequests { overviewAsked = nil }
        log?("overview #\(request) \(Int(overview.milliseconds)) ms")
        let stats = CloudRenderStats.shared
        stats.overviews += 1
        stats.overviewMilliseconds += overview.milliseconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overviewImage.bounds = CGRect(origin: .zero, size: overview.pixels)
        overviewImage.contents = overview.image
        CATransaction.commit()
        self.overview = overview
        tick()
    }

    private func ask(projection: Projection, size: CGSize, moving: Bool, clock: Double, displayScale: Double) {
        guard let inputs, let handle else { return }
        let walkKey = walkKey
        let shown = front.map { bake in
            BakePolicy.Shown(
                frame: bake.frame, fieldKey: bake.fieldKey, theme: bake.theme, clock: bake.clock,
                honeycombCurrent: honeycomb.map { $0.frame.id == bake.frame.id && $0.walkKey == walkKey } ?? false
            )
        }
        let warp = front.flatMap { BakeWarp(now: projection, frame: $0.frame) }
        let asked = lastRequest.map { last in
            BakePolicy.Asked(
                sameCamera: BakeWarp(now: projection, frame: last.frame)?.exact(size: size) ?? false,
                draft: last.frame.draft, honeycomb: last.honeycomb
            )
        }
        guard let request = BakePolicy.decide(
            shown: shown, wanted: BakePolicy.Wanted(fieldKey: inputs.key, theme: inputs.theme),
            fits: warp?.fits(size: size, now: projection, moving: moving) ?? false,
            exact: warp?.exact(size: size) ?? false,
            moving: moving, dragging: handle.isDragging, clock: clock,
            drifts: !inputs.reduceMotion && reveal == nil, asked: asked,
            flying: moving && !handle.isDragging
        ) else { return }

        let frame: BakeFrame
        switch request.frame {
        case .shown:
            guard let front else { return }
            frame = front.frame
        case .fresh(let draft):
            frame = BakeFrame.around(projection, size: size, displayScale: displayScale, draft: draft)
        }
        let job = BakeJob(
            frame: frame, field: inputs.field, fieldKey: inputs.key, theme: inputs.theme,
            clock: request.clock == .shown ? front?.clock ?? clock : clock,
            honeycomb: request.honeycomb, walkTiles: inputs.walkTiles, walkKey: walkKey,
            previous: front?.field, previousKey: front?.fieldKey
        )
        lastRequest = (frame, request.honeycomb)
        requests += 1
        let id = requests
        let askedAt = CACurrentMediaTime()
        inFlight = (id, frame, askedAt)
        // Quickly while something's standing in for it; otherwise behind the main
        // thread and MapKit for the big cores. On a Dispatch queue rather than Swift's
        // shared threads, which the app's other background work can keep busy for
        // seconds on end (and the simulator has fewer of), and which a slow bake would hold up.
        let urgent = !frontCovers
        let qos: DispatchQoS.QoSClass = urgent ? .userInitiated : .utility
        log?("ask #\(id) \(request.frame == .shown ? "same frame" : frame.draft ? "draft" : "sharp")\(urgent ? " urgent" : "")")
        let bakery = bakery
        DispatchQueue.global(qos: qos).async { [weak self] in
            let bake = bakery(job)
            DispatchQueue.main.async { self?.finished(bake, request: id, asked: askedAt) }
        }
    }

    private func finished(_ bake: CloudBake, request: Int, asked: Double) {
        let took = CACurrentMediaTime() - asked
        lastBakeSeconds = took
        if inFlight?.request == request { inFlight = nil }
        // One given up on can still turn up first; one older than what's on screen can't help.
        guard request > frontRequest else {
            log?("drop #\(request)")
            return
        }
        log?("done #\(request) \(Int(took * 1000)) ms")
        frontRequest = request
        accept(bake)
    }

    private func accept(_ bake: CloudBake) {
        let stats = CloudRenderStats.shared
        stats.bakes += 1
        if bake.frame.draft { stats.drafts += 1 }
        stats.bakeMilliseconds += bake.milliseconds
        stats.longestBake = max(stats.longestBake, bake.milliseconds)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = bake.honeycomb {
            honeycomb = (image, bake.frame, bake.job.walkKey)
            honeycombRoot.contents = image
            honeycombRoot.bounds = CGRect(origin: .zero, size: bake.frame.rect.size)
        }
        let old = front
        if let old, bake.job.previousKey == old.fieldKey, bake.fieldKey != old.fieldKey,
           !bake.leaving.isEmpty || !bake.leavingMist.isEmpty, old.field.places == bake.field.places {
            // Tiles clearing since what's on screen: open them up, or sparkle the mist off them.
            reveal = Reveal(
                started: CACurrentMediaTime(), leaving: bake.leaving, leavingMist: bake.leavingMist,
                fresh: Set(bake.leaving.map(\.tile))
            )
        } else if old == nil || old?.field.places != bake.field.places {
            reveal = nil
            cloudImage.mask = nil
            patchLayer.isHidden = true
        }
        if var reveal { reveal.frameID = nil; self.reveal = reveal }

        cloudRoot.bounds = CGRect(origin: .zero, size: bake.frame.rect.size)
        cloudImage.frame = cloudRoot.bounds
        cloudImage.contents = bake.clouds
        // The same picture with the clouds drifted on: cross-faded, as it'd be a jump.
        // Anything else is the same clouds from a slightly different camera, or new
        // tiles that open up by themselves, so it's swapped straight in.
        if let old, let from = old.clouds, old.frame.id == bake.frame.id, old.clock != bake.clock,
           old.fieldKey == bake.fieldKey, old.theme == bake.theme {
            let fade = CABasicAnimation(keyPath: "contents")
            fade.fromValue = from
            fade.toValue = bake.clouds
            fade.duration = BakePolicy.driftFade
            cloudImage.add(fade, forKey: "drift")
        } else {
            cloudImage.removeAnimation(forKey: "drift")
        }
        CATransaction.commit()
        front = bake
        tick()
    }

    // MARK: Where you are

    private func placeMarker(map: MKMapView, projection: Projection, inputs: Inputs) {
        guard let location = map.userLocation.location, projection.isInFront(MKMapPoint(location.coordinate)) else {
            marker.root.isHidden = true
            marker.accuracy.isHidden = true
            return
        }
        marker.style(inputs.marker, reduceMotion: inputs.reduceMotion, scale: map.traitCollection.displayScale)
        let ground = MKMapPoint(location.coordinate)
        marker.root.position = projection.point(ground)
        marker.root.isHidden = false
        // How sure the GPS is, as a faint patch on the ground.
        let accuracy = location.horizontalAccuracy * MKMapPointsPerMeterAtLatitude(location.coordinate.latitude)
        let patch = location.horizontalAccuracy > 0 ? projection.ellipse(centre: ground, radius: accuracy) : .null
        if !patch.isNull, patch.width > 30 {
            marker.accuracy.path = CGPath(ellipseIn: patch, transform: nil)
            marker.accuracy.isHidden = false
        } else {
            marker.accuracy.isHidden = true
        }
    }
}

/// Where you are, as layers: an orange dot (or the equipped marker) in a white ring
/// with a slow pulse, which Core Animation runs by itself.
private final class MarkerLayers {
    let root = PlainLayer()
    let accuracy = PlainShapeLayer()
    private let ring = PlainShapeLayer()
    private let dot = PlainShapeLayer()
    private let centre = PlainShapeLayer()
    private let art = PlainLayer()
    private var styled: (marker: String, reduceMotion: Bool)?

    init() {
        let orange = UIColor.walkiesOrange
        accuracy.fillColor = orange.withAlphaComponent(0.12).cgColor
        accuracy.isHidden = true
        root.isHidden = true

        ring.fillColor = nil
        ring.strokeColor = orange.cgColor
        ring.lineWidth = 3

        let white = CGPath(ellipseIn: CGRect(x: -11, y: -11, width: 22, height: 22), transform: nil)
        dot.path = white
        dot.fillColor = UIColor.white.cgColor
        dot.shadowPath = white
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowRadius = 4
        dot.shadowOffset = CGSize(width: 0, height: 2)

        centre.path = CGPath(ellipseIn: CGRect(x: -7.5, y: -7.5, width: 15, height: 15), transform: nil)
        centre.fillColor = orange.cgColor

        art.shadowColor = UIColor.black.cgColor
        art.shadowOpacity = 0.25
        art.shadowRadius = 3
        art.shadowOffset = CGSize(width: 0, height: 2)
        art.contentsGravity = .resizeAspect

        for layer in [ring, dot, centre, art] { root.addSublayer(layer) }
    }

    private static func circle(_ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    func style(_ marker: String, reduceMotion: Bool, scale: CGFloat) {
        // Animations go when the app's in the background: put the pulse back if so.
        if let styled, styled.marker == marker, styled.reduceMotion == reduceMotion,
           reduceMotion || ring.animation(forKey: "pulse") != nil { return }
        styled = (marker, reduceMotion)

        ring.removeAnimation(forKey: "pulse")
        ring.path = Self.circle(11)
        ring.opacity = 0.55
        if !reduceMotion {
            // Out from 11 to 33 points, fading as it goes, every two seconds.
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = Self.circle(11)
            grow.toValue = Self.circle(33)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [grow, fade]
            pulse.duration = 2
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            // In step with the clock, as the Canvas's was.
            pulse.timeOffset = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2)
            ring.add(pulse, forKey: "pulse")
        }

        if let asset = CosmeticArt.marker(marker), let image = UIImage(named: asset), let cgImage = image.cgImage {
            let fit = 34 / max(image.size.width, image.size.height)
            art.bounds = CGRect(x: 0, y: 0, width: image.size.width * fit, height: image.size.height * fit)
            art.position = CGPoint(x: 0, y: -3)
            art.contents = cgImage
            art.contentsScale = image.scale
            art.shouldRasterize = true
            art.rasterizationScale = scale
            art.isHidden = false
            centre.isHidden = true
        } else {
            art.isHidden = true
            centre.isHidden = false
        }
    }
}

extension CosmeticTrail {
    /// The trails drawn on the cloud layer, at a fixed size in screen points. The plain
    /// one is a line on the map itself.
    static func drawnOnCanvas(_ style: String) -> Bool {
        style == "trail.footprints" || style == "trail.sparkles" || style == "trail.rainbow"
    }
}
