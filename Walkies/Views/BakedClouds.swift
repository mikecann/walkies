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
    /// Frames the clouds round tiles clearing were drawn.
    var revealFrames = 0
}

/// Keeps the baked clouds on the map. Each frame (driven by the map telling the
/// handle its camera changed, so in step with MapKit, and by a display link for the
/// rest) it measures the projection, sets the layers' transforms to warp the bake
/// onto it, and asks for a new bake if the one on screen needs it:
///
/// - new tiles or a new look: from the same camera and drift if they still fit, so
///   the new one drops straight in (and tiles clearing open up over it);
/// - while the map moves: a rough, wide bake only once the screen's half way into
///   the margin, or zoomed or turned well past, with the drift held;
/// - once it's been still a quarter of a second: a sharp one from exactly there;
/// - still for 2.5 s: the same picture with the clouds drifted on, cross-faded in.
///
/// One bake at a time, on a background thread. One that's taking too long is given
/// up on (see `BakePolicy.giveUp`), but still shown if it turns up before a newer one.
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
        /// No bake fit to show, so the live Canvas stands in.
        var needsLive = false
    }

    let status = Status()

    /// SwiftUI makes a new engine every time the view's rebuilt and keeps only the
    /// first, so the layers are only made once one's used.
    private final class Layers {
        let cloudHost = PlainLayer()
        let markerHost = PlainLayer()
        /// The bake's box, warped onto the screen.
        let cloudRoot = PlainLayer()
        let cloudImage = PlainLayer()
        /// The clouds round tiles clearing, drawn each frame over a hole in `cloudImage`.
        let patchLayer = PlainLayer()
        let honeycombRoot = PlainLayer()
        let marker = MarkerLayers()

        init() {
            for layer in [cloudRoot, honeycombRoot] {
                layer.anchorPoint = .zero
                layer.position = .zero
                layer.isHidden = true
            }
            cloudImage.anchorPoint = .zero
            if LaunchArguments.has("-bakeOutline") {
                // `-bakeOutline`: a red edge round the bake, to see where it's warped to.
                cloudImage.borderWidth = 3
                cloudImage.borderColor = UIColor.systemRed.cgColor
            }
            patchLayer.anchorPoint = .zero
            patchLayer.isHidden = true
            cloudRoot.addSublayer(cloudImage)
            cloudRoot.addSublayer(patchLayer)
            cloudHost.addSublayer(cloudRoot)
            cloudHost.addSublayer(honeycombRoot)
            markerHost.addSublayer(marker.accuracy)
            markerHost.addSublayer(marker.root)
        }
    }
    private lazy var layers = Layers()
    var cloudHost: CALayer { layers.cloudHost }
    var markerHost: CALayer { layers.markerHost }
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
    /// The bake being made, and when it was asked for.
    private var inFlight: (request: Int, asked: Double)?
    var baking: Bool { inFlight != nil }

    /// Makes a bake, on a background thread. Tests stand in for it.
    var bakery: @Sendable (BakeJob) -> CloudBake = { CloudBakery.bake($0) }

    private struct Reveal {
        var started: Double
        var leaving: [CloudField.Puff]
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

        if let inFlight, now - inFlight.asked > BakePolicy.giveUp {
            // Stop waiting, and ask again: for the same camera too, if it's still there.
            self.inFlight = nil
            lastRequest = nil
            CloudRenderStats.shared.abandoned += 1
        }
        if !baking { ask(projection: projection, size: size, moving: moving, clock: clock, displayScale: displayScale) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let live = !place(projection: projection, now: now)
        if let map { placeMarker(map: map, projection: projection, inputs: inputs) }
        CATransaction.commit()
        if status.needsLive != live { status.needsLive = live }
        if live { CloudRenderStats.shared.liveTicks += 1 }

        // Every frame while anything's moving; otherwise just often enough to notice
        // the drift's due. The map changing wakes it straight away.
        let busy = moving || handle.isDragging || handle.honeycomb(at: .now) > 0 || reveal != nil
        if busy != linkActive, let link {
            linkActive = busy
            link.preferredFrameRateRange = busy ? .default : CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
        }
    }

    /// Warps what's baked onto the screen. False if there's nothing fit to show.
    private func place(projection: Projection, now: Double) -> Bool {
        guard let inputs, let front, front.field.places == inputs.field.places, front.theme == inputs.theme,
              let warp = BakeWarp(now: projection, frame: front.frame)
        else {
            cloudRoot.isHidden = true
            honeycombRoot.isHidden = true
            return false
        }
        cloudRoot.transform = warp.layerTransform
        cloudRoot.isHidden = false

        let opacity = handle?.honeycomb(at: .now) ?? 0
        if opacity > 0, let honeycomb, let warp = BakeWarp(now: projection, frame: honeycomb.frame) {
            honeycombRoot.transform = warp.layerTransform
            honeycombRoot.opacity = Float(opacity)
            honeycombRoot.isHidden = false
        } else {
            honeycombRoot.isHidden = true
        }
        placeReveal(front: front, now: now)
        return true
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
            reveal.patch = CloudBakery.revealPatch(field: front.field, leaving: reveal.leaving, frame: frame)
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
            field: reveal.field, leaving: reveal.leaving, reveal: progress, fresh: reveal.fresh,
            projection: frame.projection, bounds: reveal.area, clock: front.clock, puffMargin: 0, reference: reveal.reference
        )
        let sprites = CloudSprites.sprites(for: front.theme)
        patchLayer.contents = CloudBakery.render(patch, scale: frame.scale) { scene.draw(in: $0, sprites: sprites) }
        patchLayer.isHidden = false
        CloudRenderStats.shared.revealFrames += 1
    }

    // MARK: Baking

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
            drifts: !inputs.reduceMotion && reveal == nil, asked: asked
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
        inFlight = (id, CACurrentMediaTime())
        // Quickly when there's nothing to show; otherwise behind the main thread and
        // MapKit for the big cores. On a Dispatch queue rather than Swift's shared
        // threads, which the app's other background work can keep busy for seconds on
        // end (and the simulator has fewer of), and which a slow bake would hold up.
        let qos: DispatchQoS.QoSClass = front == nil || status.needsLive ? .userInitiated : .utility
        let bakery = bakery
        DispatchQueue.global(qos: qos).async { [weak self] in
            let bake = bakery(job)
            DispatchQueue.main.async { self?.finished(bake, request: id) }
        }
    }

    private func finished(_ bake: CloudBake, request: Int) {
        if inFlight?.request == request { inFlight = nil }
        // One given up on can still turn up first; one older than what's on screen can't help.
        guard request > frontRequest else { return }
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
        if let old, bake.job.previousKey == old.fieldKey, bake.fieldKey != old.fieldKey, !bake.leaving.isEmpty,
           old.field.places == bake.field.places {
            // Tiles clearing since what's on screen: open them up.
            reveal = Reveal(started: CACurrentMediaTime(), leaving: bake.leaving, fresh: Set(bake.leaving.map(\.tile)))
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
