import MapKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import simd
@testable import Walkies

// Why these live in a test target of their own: the engine's rules run on the clock
// (the first bake waits up to `BakePolicy.overviewWait` for the overview, a bake is
// given up on after `BakePolicy.giveUp`, the camera's still after `BakePolicy.settle`),
// and these tests drive the real engine with real bakes and overviews on its own
// background threads. In WalkiesTests they ran alongside every other suite, which
// all start at once and kept the simulator's cores busy: the overview, made at utility
// priority, took 3.8 s instead of 0.5, so it turned up after the first bake had given
// up waiting for it, and a 2.5 s bake ran past its 3 s limit. Each test passed on its
// own. Xcode runs the scheme's test targets one after another, so here nothing else
// is running; and they're serialized so they don't compete with each other either.

/// The baked renderer end to end: the engine's own layers, composited as Core Animation
/// would, show the clouds where the live renderer draws them, including after the
/// camera's moved without MapKit saying so.
@MainActor @Suite(.serialized)
struct BakedLayerTests {
    /// The camera the engine sees, changed under it as MapKit would.
    private final class Screen {
        var camera: TestCamera
        init(_ camera: TestCamera) { self.camera = camera }
    }

    @Test func theBakedLayersShowTheCloudsWhereTheLiveRendererDraws() async throws {
        let field = CloudFixtures.clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        let screen = Screen(camera)

        let engine = BakedCloudEngine(renderer: .baked)
        engine.testScreen = { (screen.camera.size, 3, screen.camera.projection) }
        let inputs = BakedCloudEngine.Inputs(
            field: field, key: "a", theme: "clouds.classic", walkTiles: [], marker: "marker.dot", reduceMotion: true
        )
        engine.update(inputs, handle: MapHandle())
        try await settle(engine, on: screen.camera)
        try compare(engine, with: field, on: screen.camera, "first bake")

        // MapKit moves the camera without telling the handle: the engine still notices,
        // and the clouds follow.
        screen.camera = camera.pan(60, -90).zoomed(1.15).turned(8)
        try await settle(engine, on: screen.camera)
        try compare(engine, with: field, on: screen.camera, "after the camera moved")
    }

    /// MapKit starts well in and off to one side, and the first bake's from there; then
    /// it flies out to the place, 18 times further out and tipped back, and the bake
    /// asked for on the way never finishes. The engine gives up on it, bakes again from
    /// where the camera's got to, and the clouds show there.
    @Test func aBakeThatNeverFinishesDoesntLeaveTheCloudsBehind() async throws {
        let field = CloudFixtures.clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        let start = camera.tipped(0).zoomed(18).pan(-6000, 4000)
        let screen = Screen(start)
        let gate = StuckBakery()
        defer { gate.release() }

        let engine = BakedCloudEngine(renderer: .baked)
        engine.testScreen = { (screen.camera.size, 3, screen.camera.projection) }
        engine.bakery = { gate.bake($0) }
        let inputs = BakedCloudEngine.Inputs(
            field: field, key: "a", theme: "clouds.classic", walkTiles: [], marker: "marker.dot", reduceMotion: true
        )
        engine.update(inputs, handle: MapHandle())
        try await settle(engine, on: start)

        gate.stickNext()
        screen.camera = camera
        try await settle(engine, on: camera)
        #expect(gate.stuck, "the bake after the flight should have been the stuck one")
        try compare(engine, with: field, on: camera, "after flying out past a stuck bake")
    }

    /// Opening the app: MapKit starts on its own region, zoomed right out and off to
    /// one side, and the first bake's from there. While that's being made it flies in
    /// to the place, tipped back. The clouds show the whole time, from the overview
    /// or the live Canvas; nothing's baked mid-flight; the first bake isn't waited
    /// for once it's landed; and a sharp bake from where it landed fades in.
    @Test func openingTheAppShowsCloudsAllTheWayAndLandsAFittingBake() async throws {
        let field = CloudFixtures.clearingField().after
        var target = TestCamera().zoomed(0.1).tipped(40)
        target.centre = field.clearings[0].centre
        target.size = CGSize(width: 402, height: 874)
        let start = target.tipped(0).zoomed(0.002).pan(-30, 60)
        let screen = Screen(start)
        let handle = MapHandle()
        let slow = SlowBakery(first: 1.5)
        var events: [String] = []

        let engine = BakedCloudEngine(renderer: .baked)
        engine.testScreen = { (screen.camera.size, 3, screen.camera.projection) }
        engine.bakery = { slow.bake($0) }
        engine.log = { events.append($0) }
        engine.update(field: field, handle: handle)

        // The overview's ready quickly (well under a second on a phone, slower on a
        // simulator running the suite in parallel), and stands in at once.
        try await tick(engine, until: "the overview", within: 5) { engine.overview != nil }
        engine.tick()
        #expect(engine.showingOverview, "zoomed out, the overview stands in: \(events)")
        #expect(!engine.status.needsLive)
        // The first bake, from MapKit's own region, once the camera's been still a moment.
        try await tick(engine, until: "the first bake", within: 2) { engine.baking }

        // Flies in while it's being made.
        handle.moving = true
        let asksBefore = events.filter { $0.hasPrefix("ask #") }.count
        for step in 1...12 {
            let t = Double(step) / 12
            var camera = target
            camera.zoom = start.zoom * pow(target.zoom / start.zoom, t)
            camera.pitch = target.pitch * t
            camera.centre = MKMapPoint(x: start.centre.x + (target.centre.x - start.centre.x) * t, y: start.centre.y + (target.centre.y - start.centre.y) * t)
            screen.camera = camera
            engine.tick()
            #expect(engine.showingOverview || engine.showingFront, "step \(step): bare map")
            // Never the live Canvas while the camera moves, once there's an overview.
            #expect(!engine.status.needsLive, "step \(step): drawn live mid-flight")
            if engine.showingFront, let front = engine.front {
                #expect(BakeWarp(now: camera.projection, frame: front.frame)?.shows(size: camera.size, now: camera.projection, moving: true) == true, "step \(step): a bake from far off drawn")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        handle.moving = false
        engine.tick()
        #expect(events.filter { $0.hasPrefix("ask #") }.count == asksBefore, "nothing baked mid-flight: \(events)")
        // Landed, zoomed in and tipped back: the first bake's no use here.
        #expect(!engine.showingFront)
        #expect(engine.status.needsLive || engine.showingOverview)

        let landed = Date.now
        try await settle(engine, on: target)
        let took = Date.now.timeIntervalSince(landed)
        // Either it was superseded, or (on a slow simulator) it had already finished
        // mid-flight; either way nothing waited on it and a fresh bake landed.
        #expect(events.contains { $0.hasPrefix("supersede #1") || $0.hasPrefix("done #1") || $0.hasPrefix("drop #1") }, "the first bake shouldn't be waited for: \(events)")
        #expect(engine.abandoned == 0)
        // Once it's faded in over what stood in for it.
        try await run(engine, for: BakePolicy.fade * 2 + 0.1)
        #expect(engine.showingFront && !engine.showingOverview && !engine.status.needsLive)
        try compare(engine, with: field, on: target, "after opening")
        print("Opening: sharp bake \(String(format: "%.2f", took)) s after landing. \(events)")
    }

    /// A bake that no longer looks like what's on screen (the camera zoomed well out,
    /// or panned far off, with the next one not done): while the camera's moving, it's
    /// drawn stretched as long as it's on screen at all, over the overview however
    /// soft, and never the live Canvas. Once it's still, the old bake isn't drawn: the
    /// overview stands in, or where that's too soft, the live Canvas.
    @Test func aBakeThatNoLongerFitsIsntDrawnOffTheScreen() async throws {
        let field = CloudFixtures.clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        for coarse in [false, true] {
            let screen = Screen(camera)
            let gate = StuckBakery()
            defer { gate.release() }
            let engine = BakedCloudEngine(renderer: .baked)
            if coarse { engine.overviewPixels = 400 }
            engine.testScreen = { (screen.camera.size, 3, screen.camera.projection) }
            engine.bakery = { gate.bake($0) }
            engine.update(field: field, handle: MapHandle())
            try await settle(engine, on: camera)
            try await tick(engine, until: "the overview", within: 2) { engine.overview != nil }
            try await run(engine, for: BakePolicy.fade * 2 + 0.1)
            #expect(engine.showingFront && !engine.showingOverview && !engine.status.needsLive)

            gate.stickAll()
            let away = coarse ? camera.pan(300, 0) : camera.zoomed(0.3)
            screen.camera = away
            // As the next frame would: the camera's measured at most once a few milliseconds.
            try await Task.sleep(for: .milliseconds(10))
            engine.tick()
            // Just moved: never live.
            #expect(!engine.status.needsLive, "coarse \(coarse): drawn live while moving")
            #expect(engine.showingOverview, "coarse \(coarse): the overview under it while moving, however soft")
            if coarse {
                #expect(!engine.showingFront, "panned clean off it, the old bake shouldn't be drawn")
            } else {
                #expect(engine.showingFront, "zoomed out, the old bake should be drawn shrunk while moving")
            }

            // Still, with the next bake not done.
            try await run(engine, for: BakePolicy.settle + 0.1)
            #expect(!engine.showingFront, "coarse \(coarse): the old bake shouldn't be drawn once still")
            if coarse {
                #expect(engine.status.needsLive && !engine.showingOverview, "zoomed in, the live clouds stand in")
            } else {
                #expect(engine.showingOverview && !engine.status.needsLive, "zoomed out, the overview stands in")
                try compare(engine, with: field, on: away, "the overview standing in", simple: true)
            }
        }
    }

    /// A bake that takes 2.5 s, as one can in a Debug build, is waited for, not given
    /// up on and asked for again.
    @Test func aSlowBakeIsntGivenUpOn() async throws {
        let field = CloudFixtures.clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        let screen = Screen(camera)
        let engine = BakedCloudEngine(renderer: .baked)
        engine.testScreen = { (screen.camera.size, 3, screen.camera.projection) }
        engine.update(field: field, handle: MapHandle())
        try await settle(engine, on: camera)

        let slow = SlowBakery(every: 2.5)
        engine.bakery = { slow.bake($0) }
        screen.camera = camera.pan(60, -90)
        try await settle(engine, on: screen.camera)
        #expect(engine.abandoned == 0)
        #expect(slow.count == 1, "asked \(slow.count) times")
    }

    /// Ticks the engine as its display link would for a while.
    private func run(_ engine: BakedCloudEngine, for seconds: Double) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            engine.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        engine.tick()
    }

    /// Ticks the engine as its display link would until `done`.
    private func tick(_ engine: BakedCloudEngine, until what: String, within seconds: Double, _ done: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            engine.tick()
            if done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("No \(what) within \(seconds) s")
    }

    /// Ticks the engine as its display link would, until a sharp bake from exactly
    /// this camera is on screen.
    private func settle(_ engine: BakedCloudEngine, on camera: TestCamera) async throws {
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline {
            engine.tick()
            if !engine.baking, let front = engine.front, !front.frame.draft,
               BakeWarp(now: camera.projection, frame: front.frame)?.exact(size: camera.size) == true {
                engine.tick()
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No bake from the camera now within 15 s; the one on screen is from \(String(describing: engine.front?.frame.projection))")
    }

    /// Samples the screen every few points: wherever the live renderer draws solid
    /// cloud, the baked layers show cloud, and where it draws none, they show none.
    private func compare(
        _ engine: BakedCloudEngine, with field: CloudField, on camera: TestCamera, _ label: String, simple: Bool = false
    ) throws {
        let size = camera.size
        let bounds = CGRect(origin: .zero, size: size)
        var scene = CloudScene(field: field, projection: camera.projection, bounds: bounds, clock: 0)
        // The overview draws only the puffs' tops, as zoomed right out.
        if simple { scene.detail = 0 }
        let live = try #require(CloudBakery.render(bounds, scale: 1) { scene.draw(in: $0, sprites: CloudSprites.sprites(for: "clouds.classic")) })
        let liveAlpha = Alphas(live)
        var composite = Composite()
        var cloudy = 0, cloudyShown = 0, clear = 0, clearShown = 0
        for y in stride(from: 3.0, to: Double(size.height), by: 6) {
            for x in stride(from: 3.0, to: Double(size.width), by: 6) {
                let expected = liveAlpha.at(x / Double(size.width), y / Double(size.height))
                let shown = composite.alpha(engine.cloudHost, at: CGPoint(x: x, y: y))
                if expected > 200 {
                    cloudy += 1
                    if shown > 128 { cloudyShown += 1 }
                } else if expected < 8 {
                    clear += 1
                    if shown > 64 { clearShown += 1 }
                }
            }
        }
        #expect(cloudy > 100, "\(label): the live renderer should have plenty of cloud on screen, has \(cloudy) points")
        #expect(clear > 50, "\(label): and some clear map, has \(clear) points")
        #expect(Double(cloudyShown) >= Double(cloudy) * 0.95, "\(label): \(cloudyShown) of \(cloudy) cloudy points show cloud")
        #expect(Double(clearShown) <= Double(clear) * 0.05, "\(label): \(clearShown) of \(clear) clear points show cloud")
    }

    /// The layer host fills the view SwiftUI gives it, with the layer the same size.
    @Test func theLayerHostFillsItsView() throws {
        let layer = CALayer()
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: LayerHost(layer: layer).ignoresSafeArea())
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        let view = try #require(layer.superlayer?.delegate as? UIView)
        view.layoutIfNeeded()
        #expect(view.window === window)
        #expect(view.convert(view.bounds, to: window) == window.bounds)
        #expect(layer.frame == view.bounds)
        #expect(!view.clipsToBounds)
    }
}

/// Bakes as the app does, except the first one after `stickNext()` (or every one
/// after `stickAll()`), which doesn't finish until `release()`.
nonisolated private final class StuckBakery: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = false
    private var always = false
    private var held = false
    private var waiting = 0
    private var released = false

    var stuck: Bool { lock.withLock { held } }

    func stickNext() { lock.withLock { armed = true } }

    func stickAll() { lock.withLock { always = true } }

    func release() {
        let count = lock.withLock {
            released = true
            return max(1, waiting)
        }
        for _ in 0..<count { gate.signal() }
    }

    func bake(_ job: BakeJob) -> CloudBake {
        let stick = lock.withLock {
            defer { armed = false }
            let stick = (armed || always) && !released
            if stick {
                held = true
                waiting += 1
            }
            return stick
        }
        if stick { gate.wait() }
        return CloudBakery.bake(job)
    }
}

/// Bakes as the app does, but slower: the first one by `first` seconds, or every one
/// by `every`, as a Debug build in the simulator might.
nonisolated private final class SlowBakery: @unchecked Sendable {
    private let lock = NSLock()
    private var bakes = 0
    private let first: Double
    private let every: Double

    init(first: Double = 0, every: Double = 0) {
        self.first = first
        self.every = every
    }

    var count: Int { lock.withLock { bakes } }

    func bake(_ job: BakeJob) -> CloudBake {
        let n = lock.withLock { bakes += 1; return bakes }
        let started = Date.now
        let bake = CloudBakery.bake(job)
        let delay = (n == 1 ? first : 0) + every - Date.now.timeIntervalSince(started)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return bake
    }
}

extension BakedCloudEngine {
    func update(field: CloudField, handle: MapHandle) {
        update(Inputs(field: field, key: "a", theme: "clouds.classic", walkTiles: [], marker: "marker.dot", reduceMotion: true), handle: handle)
    }
}

/// Composites a layer tree at one point as Core Animation would, for the shapes the
/// engine builds: layers placed by position, anchor point, bounds and a (perspective)
/// transform with z = 0, showing images as their contents. Hidden or see-through
/// layers show nothing. A mask (only there while tiles clear) isn't taken into account.
private struct Composite {
    /// Each image's alphas, read once. The images are all held by the layers meanwhile.
    private var read: [ObjectIdentifier: Alphas] = [:]

    mutating func alpha(_ layer: CALayer, at p: CGPoint) -> Int {
        guard !layer.isHidden, layer.opacity > 0, let local = Self.unproject(layer, p) else { return 0 }
        var shown = 0
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            let image = contents as! CGImage
            let b = layer.bounds
            if b.width > 0, b.height > 0, b.contains(local) {
                let alphas = read[ObjectIdentifier(image)] ?? Alphas(image)
                read[ObjectIdentifier(image)] = alphas
                shown = alphas.at((local.x - b.minX) / b.width, (local.y - b.minY) / b.height)
            }
        }
        for sublayer in layer.sublayers ?? [] {
            shown = max(shown, alpha(sublayer, at: local))
        }
        return Int(Double(shown) * Double(layer.opacity))
    }

    /// A point in the superlayer to one in `layer`'s bounds.
    private static func unproject(_ layer: CALayer, _ p: CGPoint) -> CGPoint? {
        let t = layer.transform
        let b = layer.bounds
        let anchor = CGPoint(x: b.minX + layer.anchorPoint.x * b.width, y: b.minY + layer.anchorPoint.y * b.height)
        // Rows of CA's [x y 0 1] times the transform, as a column-vector homography.
        let h = simd_double3x3(rows: [
            SIMD3(Double(t.m11), Double(t.m21), Double(t.m41)),
            SIMD3(Double(t.m12), Double(t.m22), Double(t.m42)),
            SIMD3(Double(t.m14), Double(t.m24), Double(t.m44)),
        ])
        guard abs(h.determinant) > 1e-12 else { return nil }
        let d = h.inverse * SIMD3(Double(p.x - layer.position.x), Double(p.y - layer.position.y), 1)
        guard d.z > 0 else { return nil }
        return CGPoint(x: d.x / d.z + anchor.x, y: d.y / d.z + anchor.y)
    }
}
