import MapKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import simd
@testable import Walkies

/// A stand-in for MapKit's camera: looking down on `centre` from above, turned to
/// `heading` and tipped back by `pitch`, `zoom` screen points to the map point.
private struct TestCamera {
    var centre = MKMapPoint(CLLocationCoordinate2D(latitude: -33.64, longitude: 115.39))
    var zoom = 0.5
    var heading = 0.0
    var pitch = 0.0
    var size = CGSize(width: 414, height: 896)
    /// How far the camera is from the middle of the screen, in screen points.
    static let distance = 1000.0

    func pan(_ dx: Double, _ dy: Double) -> TestCamera {
        var c = self
        // A drag of (dx, dy) points moves the ground the other way.
        let h = heading * .pi / 180
        let gx = (cos(h) * dx - sin(h) * dy) / zoom, gy = (sin(h) * dx + cos(h) * dy) / zoom
        c.centre = MKMapPoint(x: centre.x + gx, y: centre.y + gy)
        return c
    }

    func zoomed(_ f: Double) -> TestCamera { var c = self; c.zoom *= f; return c }
    func turned(_ degrees: Double) -> TestCamera { var c = self; c.heading += degrees; return c }
    func tipped(_ degrees: Double) -> TestCamera { var c = self; c.pitch = degrees; return c }

    /// A ground point on screen, or nil if it's behind the camera.
    func screen(_ p: MKMapPoint) -> CGPoint? {
        let h = heading * .pi / 180, t = pitch * .pi / 180
        let dx = p.x - centre.x, dy = p.y - centre.y
        let rx = (cos(h) * dx + sin(h) * dy) * zoom
        let ry = (-sin(h) * dx + cos(h) * dy) * zoom
        let w = 1 - ry * sin(t) / Self.distance
        guard w > 0 else { return nil }
        return CGPoint(x: rx / w + size.width / 2, y: ry * cos(t) / w + size.height / 2)
    }

    /// The ground under a screen point.
    func ground(_ s: CGPoint) -> MKMapPoint {
        let h = heading * .pi / 180, t = pitch * .pi / 180
        let x = Double(s.x - size.width / 2), y = Double(s.y - size.height / 2)
        let ry = y / (cos(t) + y * sin(t) / Self.distance)
        let w = 1 - ry * sin(t) / Self.distance
        let rx = x * w
        let dx = (cos(h) * rx - sin(h) * ry) / zoom, dy = (sin(h) * rx + cos(h) * ry) / zoom
        return MKMapPoint(x: centre.x + dx, y: centre.y + dy)
    }

    /// Measured as the app measures MapKit's.
    var projection: Projection {
        let screen = Projection.spots.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) }
        return Projection(ground: screen.map(ground), screen: screen, width: Double(size.width), centre: centre)
    }
}

/// Where Core Animation puts a layer point, for a layer with its anchor at (0, 0).
private func apply(_ t: CATransform3D, _ p: CGPoint) -> CGPoint {
    let x = Double(p.x), y = Double(p.y)
    let w = x * t.m14 + y * t.m24 + t.m44
    return CGPoint(x: (x * t.m11 + y * t.m21 + t.m41) / w, y: (x * t.m12 + y * t.m22 + t.m42) / w)
}

private func close(_ a: CGPoint, _ b: CGPoint, within: Double) -> Bool {
    abs(a.x - b.x) <= within && abs(a.y - b.y) <= within
}

/// A pixel on a 3x screen.
private let pixel = 1.0 / 3

/// The maths that lets a bake of the clouds stand in for drawing them every frame.
struct CloudBakeTests {
    fileprivate let base = TestCamera()
    fileprivate let moves: [(String, (TestCamera) -> TestCamera)] = [
        ("pan", { $0.pan(140, -260) }),
        ("zoom in", { $0.zoomed(1.3) }),
        ("zoom out", { $0.zoomed(0.6) }),
        ("turn", { $0.turned(25) }),
        ("tilt", { $0.tipped(40) }),
        ("all", { $0.turned(-90).pan(-200, 120).zoomed(1.2).tipped(30) }),
    ]

    @Test func theProjectionMatchesTheCamera() {
        for camera in [base, base.tipped(55).turned(30)] {
            let p = camera.projection
            #expect(p.isValid)
            for i in 0...6 {
                for j in 0...6 {
                    let s = CGPoint(x: camera.size.width * Double(i) / 6, y: camera.size.height * Double(j) / 6)
                    #expect(close(p.point(camera.ground(s)), s, within: 0.01))
                }
            }
        }
    }

    /// The bake's box, warped by the layer transform, lands exactly where the camera
    /// now sees the ground under its corners and under the four measured spots.
    @Test func theBakesCornersLandOnTheGroundUnderThem() throws {
        let then = base.tipped(20)
        let frame = BakeFrame.around(then.projection, size: then.size, displayScale: 3, draft: false)
        for (name, move) in moves {
            let now = move(then)
            let warp = try #require(BakeWarp(now: now.projection, frame: frame), "\(name)")
            let t = warp.layerTransform
            let r = frame.rect
            var points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            points += Projection.spots.map { CGPoint(x: $0.0 * then.size.width, y: $0.1 * then.size.height) }
            for p in points {
                guard let expected = now.screen(then.ground(p)) else { continue }
                let local = CGPoint(x: p.x - r.minX, y: p.y - r.minY)
                #expect(close(apply(t, local), expected, within: pixel), "\(name) at \(p)")
            }
        }
    }

    /// Anywhere on the ground, drawing it into the bake and warping that by the layer
    /// transform puts it where the projection now would, to well within a pixel.
    @Test func theWarpPutsTheBakeWhereTheProjectionWould() throws {
        let then = base.tipped(35).turned(10)
        let bake = then.projection
        let frame = BakeFrame.around(bake, size: then.size, displayScale: 3, draft: false)
        var checked = 0
        for (name, move) in moves {
            let now = move(then).projection
            let warp = try #require(BakeWarp(now: now, frame: frame), "\(name)")
            let t = warp.layerTransform
            for i in 0...8 {
                for j in 0...8 {
                    let s = CGPoint(x: then.size.width * (-0.1 + 1.2 * Double(i) / 8), y: then.size.height * (-0.1 + 1.2 * Double(j) / 8))
                    let ground = then.ground(s)
                    guard now.isInFront(ground), bake.isInFront(ground) else { continue }
                    let inBake = bake.point(ground)
                    let local = CGPoint(x: inBake.x - frame.rect.minX, y: inBake.y - frame.rect.minY)
                    #expect(close(apply(t, local), now.point(ground), within: pixel), "\(name)")
                    #expect(close(try #require(warp.map(inBake)), now.point(ground), within: pixel))
                    checked += 1
                }
            }
        }
        #expect(checked > 300)
    }

    @Test func aBakeFitsUntilTheCameraMovesTooFar() {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: false)
        func fits(_ camera: TestCamera, moving: Bool = false) -> Bool {
            BakeWarp(now: camera.projection, frame: frame)?.fits(size: base.size, now: camera.projection, moving: moving) ?? false
        }
        func exact(_ camera: TestCamera) -> Bool {
            BakeWarp(now: camera.projection, frame: frame)?.exact(size: base.size) ?? false
        }
        #expect(fits(base))
        #expect(exact(base))
        // A small pan or zoom is just a warp of what's there.
        #expect(fits(base.pan(30, 50)))
        #expect(!exact(base.pan(30, 50)))
        #expect(fits(base.zoomed(1.1)))
        // Off the edge, zoomed or turned too far, or tilted: baked again.
        #expect(!fits(base.pan(120, 0)))
        #expect(!fits(base.pan(0, -200)))
        #expect(!fits(base.zoomed(1.5)))
        #expect(!fits(base.zoomed(0.65)))
        #expect(!fits(base.turned(10)))
        #expect(!fits(base.tipped(30)))
    }

    /// Mid-pan a rough bake is left alone longer, but asked for again before its edge shows.
    @Test func aRoughBakeLastsWhileTheMapMoves() {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: true)
        func fits(_ camera: TestCamera, moving: Bool) -> Bool {
            BakeWarp(now: camera.projection, frame: frame)?.fits(size: base.size, now: camera.projection, moving: moving) ?? false
        }
        #expect(!fits(base.zoomed(1.4), moving: false))
        #expect(fits(base.zoomed(1.4), moving: true))
        #expect(fits(base.turned(6), moving: true))
        let pan = Double(base.size.width) * BakeFrame.draftMargin * 0.75
        #expect(!fits(base.pan(pan, 0), moving: true))
        #expect(fits(base.pan(pan / 3, 0), moving: true))
    }

    @Test func theFrameCoversTheScreenWithAMarginAndKeepsToItsBudget() {
        let size = base.size
        for draft in [false, true] {
            let frame = BakeFrame.around(base.projection, size: size, displayScale: 3, draft: draft)
            let margin = draft ? BakeFrame.draftMargin : BakeFrame.margin
            #expect(abs(frame.rect.minX + size.width * margin) < 0.01)
            #expect(abs(frame.rect.maxX - size.width * (1 + margin)) < 0.01)
            #expect(abs(frame.rect.minY + size.height * margin) < 0.01)
            #expect(abs(frame.rect.maxY - size.height * (1 + margin)) < 0.01)
            #expect(Double(frame.pixelWidth * frame.pixelHeight) <= BakeFrame.maxPixels * 1.01)
            #expect(frame.draft == draft)
        }
        // An XS Max's screen and margin bakes at 2 pixels a point still, 1 moving.
        #expect(BakeFrame.around(base.projection, size: size, displayScale: 3, draft: false).scale == 2)
        #expect(BakeFrame.around(base.projection, size: size, displayScale: 3, draft: true).scale == 1)
        // A 2x phone isn't baked any sharper than its screen.
        #expect(BakeFrame.around(base.projection, size: size, displayScale: 2, draft: false).scale == 2)
        // A much bigger screen bakes softer rather than bigger.
        var big = base
        big.size = CGSize(width: 1366, height: 1024)
        let frame = BakeFrame.around(big.projection, size: big.size, displayScale: 2, draft: false)
        #expect(frame.scale < 2)
        #expect(Double(frame.pixelWidth * frame.pixelHeight) <= BakeFrame.maxPixels * 1.01)
    }

    /// Tilted right up, the horizon's on screen: the bake stops short of it, so it can
    /// always be warped, and the sky above it doesn't count against it fitting.
    @Test func aSteepBakeStopsShortOfTheHorizon() {
        let steep = base.tipped(80)
        let p = steep.projection
        let frame = BakeFrame.around(p, size: steep.size, displayScale: 3, draft: false)
        #expect(frame.rect.minY > 0)
        #expect(BakeWarp(now: p, frame: frame) != nil)
        #expect(BakeWarp(now: p, frame: frame)?.fits(size: steep.size, now: p) == true)
        // Flat on, there's no horizon to stop for.
        let flat = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: false)
        #expect(abs(flat.rect.minY + base.size.height * BakeFrame.margin) < 0.01)
    }

    // MARK: When to bake

    private func shown(draft: Bool = false, clock: Double = 100, honeycomb: Bool = true) -> BakePolicy.Shown {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: draft)
        return BakePolicy.Shown(frame: frame, fieldKey: "a", theme: "clouds.classic", clock: clock, honeycombCurrent: honeycomb)
    }

    private let wanted = BakePolicy.Wanted(fieldKey: "a", theme: "clouds.classic")

    private func decide(
        _ shown: BakePolicy.Shown?, wanted: BakePolicy.Wanted? = nil, fits: Bool = true, exact: Bool = true,
        moving: Bool = false, dragging: Bool = false, clock: Double = 101, drifts: Bool = true, asked: BakePolicy.Asked? = nil
    ) -> BakePolicy.Request? {
        BakePolicy.decide(
            shown: shown, wanted: wanted ?? self.wanted, fits: fits, exact: exact, moving: moving,
            dragging: dragging, clock: clock, drifts: drifts, asked: asked
        )
    }

    @Test func theFirstBakeIsAskedForStraightAway() {
        #expect(decide(nil) == .init(frame: .fresh(draft: false), clock: .now, honeycomb: true))
        #expect(decide(nil, moving: true) == .init(frame: .fresh(draft: true), clock: .now, honeycomb: true))
    }

    @Test func newTilesDropStraightInWhenTheyCan() {
        let tiles = BakePolicy.Wanted(fieldKey: "b", theme: "clouds.classic")
        #expect(decide(shown(), wanted: tiles) == .init(frame: .shown, clock: .shown, honeycomb: true))
        #expect(decide(shown(), wanted: tiles, fits: false, moving: true) == .init(frame: .fresh(draft: true), clock: .shown, honeycomb: true))
        #expect(decide(shown(), wanted: tiles, fits: false) == .init(frame: .fresh(draft: false), clock: .now, honeycomb: true))
        // So does a new look.
        let look = BakePolicy.Wanted(fieldKey: "a", theme: "clouds.storm")
        #expect(decide(shown(), wanted: look) == .init(frame: .shown, clock: .shown, honeycomb: true))
    }

    @Test func whileMovingOnlyWhenTheBakeRunsOut() {
        #expect(decide(shown(), fits: true, exact: false, moving: true) == nil)
        #expect(decide(shown(), fits: false, exact: false, moving: true) == .init(frame: .fresh(draft: true), clock: .shown, honeycomb: false))
        #expect(decide(shown(), fits: false, exact: false, moving: true, dragging: true) == .init(frame: .fresh(draft: true), clock: .shown, honeycomb: true))
        // Not again for the camera it was last asked for.
        let asked = BakePolicy.Asked(sameCamera: true, draft: true, honeycomb: false)
        #expect(decide(shown(), fits: false, exact: false, moving: true, asked: asked) == nil)
    }

    @Test func onceStillItsBakedSharpFromRightThere() {
        let sharp = BakePolicy.Request(frame: .fresh(draft: false), clock: .shown, honeycomb: true)
        #expect(decide(shown(draft: true)) == sharp)
        #expect(decide(shown(), exact: false) == sharp)
        #expect(decide(shown(), fits: false, exact: false) == sharp)
        #expect(decide(shown(honeycomb: false)) == sharp)
        // But only once.
        #expect(decide(shown(draft: true), asked: .init(sameCamera: true, draft: false, honeycomb: true)) == nil)
        #expect(decide(shown(draft: true), asked: .init(sameCamera: false, draft: false, honeycomb: true)) == sharp)
    }

    @Test func stillTheCloudsDriftOnEveryFewSeconds() {
        #expect(decide(shown(clock: 100), clock: 101) == nil)
        let drift = BakePolicy.Request(frame: .shown, clock: .now, honeycomb: false)
        #expect(decide(shown(clock: 100), clock: 100 + BakePolicy.driftPeriod) == drift)
        // Not with reduce motion on, or while tiles clear.
        #expect(decide(shown(clock: 100), clock: 110, drifts: false) == nil)
    }

    // MARK: Tiles clearing

    @Test func theRevealPatchCoversTheClearingTilesOnTheBakesPixels() throws {
        let field = CloudTests().clearingField()
        var centred = base.zoomed(0.2)
        centred.centre = field.after.clearings[0].centre
        let frame = BakeFrame.around(centred.projection, size: centred.size, displayScale: 3, draft: false)
        let leaving = field.before.puffs.filter { puff in !field.after.puffs.contains { $0.tile == puff.tile } }
        #expect(!leaving.isEmpty)
        let patch = try #require(CloudBakery.revealPatch(field: field.after, leaving: leaving, frame: frame))
        #expect(frame.rect.contains(patch))
        // On whole pixels of the bake.
        for edge in [patch.minX - frame.rect.minX, patch.minY - frame.rect.minY, patch.width, patch.height] {
            let pixels = Double(edge) * frame.scale
            #expect(abs(pixels - pixels.rounded()) < 1e-6)
        }
        // Round every cloud that's leaving.
        let p = frame.projection
        for puff in leaving {
            let r = p.ellipse(centre: puff.centre, radius: puff.radius)
            #expect(patch.contains(CGPoint(x: r.midX, y: r.midY)))
        }
        // What's drawn every frame takes in everything that reaches into it.
        let near = CloudBakery.near(patch.insetBy(dx: -patch.width, dy: -patch.height), in: field.after, projection: p)
        let kept = Set(near.puffs.map(\.tile))
        for puff in field.after.puffs where p.ellipse(centre: puff.centre, radius: puff.radius).intersects(patch) {
            #expect(kept.contains(puff.tile))
        }
        #expect(near.clearings.count == 1)
        // But not the whole place, zoomed in.
        var close = centred.zoomed(4)
        close.centre = centred.centre
        let closeFrame = BakeFrame.around(close.projection, size: close.size, displayScale: 3, draft: false)
        let closePatch = try #require(CloudBakery.revealPatch(field: field.after, leaving: leaving, frame: closeFrame))
        let closeNear = CloudBakery.near(closePatch.insetBy(dx: -closePatch.width, dy: -closePatch.height), in: field.after, projection: closeFrame.projection)
        #expect(closeNear.puffs.count < field.after.puffs.count)
    }

    /// A bake has clouds where the puffs are, and a hole once the tile's walked.
    /// A street running off towards a tilted camera, or across one MapKit's midway
    /// through flying, can be millions of points long on screen. Dashed all the way, a
    /// bake took minutes; cut down to round what's drawn, it's quick.
    @Test func aStreetRunningFarOffTheScreenBakesQuickly() throws {
        var field = CloudTests().clearingField().after
        var camera = TestCamera().zoomed(0.1)
        camera.centre = field.clearings[0].centre
        let near = camera.ground(CGPoint(x: 200, y: 400))
        // Ten billion points away on screen.
        let far = MKMapPoint(x: near.x + 1e11, y: near.y + 3e10)
        field.lines = [CloudField.Line(points: [near, far], kind: .road)]
        let bounds = CGRect(origin: .zero, size: camera.size)
        let scene = CloudScene(field: field, projection: camera.projection, bounds: bounds, clock: 0)
        #expect(!scene.roads.isEmpty)
        let started = Date.now
        let image = CloudBakery.render(bounds, scale: 2) { scene.draw(in: $0, sprites: CloudSprites.sprites(for: "clouds.classic")) }
        #expect(image != nil)
        // Generous: it guards the minute-long case, and the simulator is slow when tests run in parallel.
        #expect(Date.now.timeIntervalSince(started) < 3, "took \(Date.now.timeIntervalSince(started)) s")
    }

    @Test func aDashedLineIsCutByWholeDashes() throws {
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cut = try #require(CloudScene.cut(CGPoint(x: -1000, y: 50), CGPoint(x: 1e9, y: 50), to: area, pattern: 7))
        #expect(cut.startCut && cut.endCut)
        // Starts at or just before the edge, a whole number of dashes from the line's own start.
        #expect(cut.from.x <= 0 && cut.from.x > -7)
        #expect(abs((Double(cut.from.x) + 1000).remainder(dividingBy: 7)) < 1e-6)
        #expect(close(cut.to, CGPoint(x: 100, y: 50), within: 1e-6))
        let inside = try #require(CloudScene.cut(CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 30), to: area, pattern: 7))
        #expect(inside.from == CGPoint(x: 10, y: 10) && inside.to == CGPoint(x: 20, y: 30) && !inside.startCut && !inside.endCut)
        #expect(CloudScene.cut(CGPoint(x: -10, y: -10), CGPoint(x: 200, y: -5), to: area, pattern: 7) == nil)
    }

    @Test func aBakeDrawsTheCloudsWithHolesInThem() throws {
        let fields = CloudTests().clearingField()
        let walked = fields.after.clearings[0].centre
        var camera = base.zoomed(0.2)
        camera.centre = walked
        let frame = BakeFrame.around(camera.projection, size: camera.size, displayScale: 2, draft: false)
        func bake(_ field: CloudField) throws -> (CloudBake, CGImage) {
            let job = BakeJob(
                frame: frame, field: field, fieldKey: "a", theme: "clouds.classic", clock: 0,
                honeycomb: true, walkTiles: [], walkKey: 0, previous: nil, previousKey: nil
            )
            let bake = CloudBakery.bake(job)
            return (bake, try #require(bake.clouds))
        }
        func alpha(_ image: CGImage, at ground: MKMapPoint) -> Int {
            let s = frame.projection.point(ground)
            let x = Int((s.x - frame.rect.minX) * frame.scale), y = Int((s.y - frame.rect.minY) * frame.scale)
            let data = image.dataProvider!.data! as Data
            // BGRA, premultiplied: alpha's the fourth byte.
            return Int(data[y * image.bytesPerRow + x * 4 + 3])
        }
        let (before, cloudy) = try bake(fields.before)
        let (after, cleared) = try bake(fields.after)
        #expect(cloudy.width == frame.pixelWidth && cloudy.height == frame.pixelHeight)
        #expect(before.honeycomb != nil && after.honeycomb != nil)
        #expect(alpha(cloudy, at: walked) > 240)
        // Only a shadow or two left over the hole.
        #expect(alpha(cleared, at: walked) < alpha(cloudy, at: walked) - 80)
    }
}

/// The baked renderer end to end: the engine's own layers, composited as Core Animation
/// would, show the clouds where the live renderer draws them, including after the
/// camera's moved without MapKit saying so.
@MainActor
struct BakedLayerTests {
    /// The camera the engine sees, changed under it as MapKit would.
    private final class Screen {
        var camera: TestCamera
        init(_ camera: TestCamera) { self.camera = camera }
    }

    @Test func theBakedLayersShowTheCloudsWhereTheLiveRendererDraws() async throws {
        let field = CloudTests().clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        let screen = Screen(camera)

        let engine = BakedCloudEngine()
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
        let field = CloudTests().clearingField().after
        var camera = TestCamera().zoomed(0.1).tipped(40)
        camera.centre = field.clearings[0].centre
        camera.size = CGSize(width: 402, height: 874)
        let start = camera.tipped(0).zoomed(18).pan(-6000, 4000)
        let screen = Screen(start)
        let gate = StuckBakery()
        defer { gate.release() }

        let engine = BakedCloudEngine()
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
    private func compare(_ engine: BakedCloudEngine, with field: CloudField, on camera: TestCamera, _ label: String) throws {
        let size = camera.size
        let bounds = CGRect(origin: .zero, size: size)
        let scene = CloudScene(field: field, projection: camera.projection, bounds: bounds, clock: 0)
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

/// Bakes as the app does, except the first one after `stickNext()`, which doesn't
/// finish until `release()`.
nonisolated private final class StuckBakery: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed = false
    private var held = false

    var stuck: Bool { lock.withLock { held } }

    func stickNext() { lock.withLock { armed = true } }

    func release() { gate.signal() }

    func bake(_ job: BakeJob) -> CloudBake {
        let stick = lock.withLock {
            defer { armed = false }
            if armed { held = true }
            return armed
        }
        if stick { gate.wait() }
        return CloudBakery.bake(job)
    }
}

/// The alpha of every pixel of an image, rows from the top.
private struct Alphas {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        data = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    /// At a point given as fractions of the width and height.
    func at(_ fx: Double, _ fy: Double) -> Int {
        let x = min(width - 1, max(0, Int(fx * Double(width)))), y = min(height - 1, max(0, Int(fy * Double(height))))
        return Int(data[y * width + x])
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

extension CloudTests {
    /// A block of street tiles, then the same with the middle one walked.
    func clearingField() -> (before: CloudField, after: CloudField) {
        var tiles = Set<Hex>()
        for q in -4...4 {
            for r in -4...4 { tiles.insert(hex(q: Int32(q), r: Int32(r))) }
        }
        let before = city(tiles: tiles, visited: [])
        var after = before
        after.visited = [hex(q: 0, r: 0)]
        return (CloudField(city: before), CloudField(city: after))
    }
}
