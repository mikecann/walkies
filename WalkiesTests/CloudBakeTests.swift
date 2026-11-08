import MapKit
import QuartzCore
import SwiftUI
import Testing
import UIKit
import simd
@testable import Walkies

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

    /// With 3D elevation on, the ground MapKit finds under a screen point follows the
    /// buildings and hills there, and shifts as they slide under it. Those shifts mustn't
    /// reach the clouds: only where a coordinate lands on screen should place them.
    @Test func bumpsUnderTheMeasuringSpotsDontMoveTheClouds() {
        let camera = base.tipped(55).turned(30)
        var bump = 0.0
        func bumpy(_ s: CGPoint) -> CLLocationCoordinate2D {
            bump += 1
            let g = camera.ground(s)
            return MKMapPoint(x: g.x + 6 * sin(bump * 2.1), y: g.y + 6 * cos(bump * 1.3)).coordinate
        }
        let p = Projection.measure(
            size: camera.size, centre: camera.centre,
            coordinateAt: bumpy,
            pointAt: { camera.screen(MKMapPoint($0)) ?? .zero }
        )
        // Fitted the old way, to the screen spots themselves, those bumps do show.
        let spots = Projection.spots.map { CGPoint(x: $0.0 * camera.size.width, y: $0.1 * camera.size.height) }
        let unsteady = Projection(ground: spots.map { MKMapPoint(bumpy($0)) }, screen: spots, width: Double(camera.size.width), centre: camera.centre)
        var worst = 0.0
        for i in 0...6 {
            for j in 0...6 {
                let s = CGPoint(x: camera.size.width * Double(i) / 6, y: camera.size.height * (0.3 + 0.7 * Double(j) / 6))
                let g = camera.ground(s)
                #expect(close(p.point(g), s, within: 0.01))
                let u = unsteady.point(g)
                worst = max(worst, hypot(u.x - s.x, u.y - s.y))
            }
        }
        #expect(worst > 1)
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
        // An XS Max's screen and margin bakes its lines at 1.5 pixels a point still, 1
        // moving, and its clouds at 1 and a half.
        let still = BakeFrame.around(base.projection, size: size, displayScale: 3, draft: false)
        let moving = BakeFrame.around(base.projection, size: size, displayScale: 3, draft: true)
        #expect(still.scale == 1.5 && still.cloudScale == 1)
        #expect(moving.scale == 1 && moving.cloudScale == 0.5)
        #expect(still.cloudPixelWidth * still.cloudPixelHeight < still.pixelWidth * still.pixelHeight)
        // A 1x screen isn't baked any sharper than itself.
        #expect(BakeFrame.around(base.projection, size: size, displayScale: 1, draft: false).scale == 1)
        // A much bigger screen bakes softer rather than bigger.
        var big = base
        big.size = CGSize(width: 1366, height: 1024)
        let frame = BakeFrame.around(big.projection, size: big.size, displayScale: 2, draft: false)
        #expect(frame.scale < 1.5 && frame.cloudScale < 1)
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

    /// A bake from a camera that's since flown far off isn't shown at all, rather than
    /// warped off the screen or to a speck; one that's only been panned a little shows,
    /// with the overview round it once the screen's past its edge.
    /// A fast pan runs the middle of the screen off a bake before the next is ready: the
    /// lines and honeycomb keep showing what's left of it, rather than blinking off.
    @Test func whatsLeftOfABakeShowsWhileTheMapMoves() throws {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: true)
        func check(_ camera: TestCamera) -> (shows: Bool, anywhere: Bool) {
            guard let warp = BakeWarp(now: camera.projection, frame: frame) else { return (false, false) }
            return (warp.shows(size: camera.size, now: camera.projection, moving: true), warp.showsAnywhere(size: camera.size, now: camera.projection))
        }
        #expect(check(base) == (true, true))
        // Panned until the middle of the screen's off the bake: still some of it on screen.
        let off = try #require(stride(from: 10.0, to: 3000, by: 10).first { !check(base.pan($0, 0)).shows })
        #expect(check(base.pan(off, 0)).anywhere)
        // Right off it, nothing.
        #expect(!check(base.pan(off * 4, 0)).anywhere)
    }

    @Test func aBakeOnlyShowsWhileItLooksLikeWhatsOnScreen() {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: false)
        func check(_ camera: TestCamera) -> (shows: Bool, covers: Bool) {
            guard let warp = BakeWarp(now: camera.projection, frame: frame) else { return (false, false) }
            return (warp.shows(size: camera.size, now: camera.projection), warp.covers(size: camera.size, now: camera.projection))
        }
        #expect(check(base) == (true, true))
        #expect(check(base.pan(20, 30)) == (true, true))
        // Past its margin: still shown, but not all of the screen.
        #expect(check(base.pan(80, 0)) == (true, false))
        #expect(check(base.zoomed(0.8)) == (true, false))
        // Flown far off, or zoomed so far it'd be a speck or a blur.
        #expect(check(base.pan(3000, 0)).shows == false)
        #expect(check(base.zoomed(0.25)).shows == false)
        #expect(check(base.zoomed(4)).shows == false)
        #expect(check(base.zoomed(1 / 2000.0)).shows == false)
        // While the map moves, stretched or shrunk a good way further, as that's better
        // than drawing the clouds live; but still not flown off, or to a speck.
        func moving(_ camera: TestCamera) -> Bool {
            BakeWarp(now: camera.projection, frame: frame)?.shows(size: camera.size, now: camera.projection, moving: true) ?? false
        }
        #expect(moving(base.zoomed(0.25)))
        #expect(moving(base.zoomed(4)))
        #expect(moving(base.pan(80, 0)))
        #expect(!moving(base.pan(3000, 0)))
        #expect(!moving(base.zoomed(0.1)))
        #expect(!moving(base.zoomed(1 / 2000.0)))
    }

    /// The overview, warped through its turned window, puts every bit of the ground
    /// where the camera sees it, looking straight down or tilted right back, where
    /// much of the place is behind the camera.
    @Test func theOverviewLandsOnTheGroundUnderIt() throws {
        let field = CloudFixtures.clearingField().after
        let overview = CloudBakery.overview(field: field, fieldKey: "a", theme: "clouds.classic", clock: 0)
        #expect(overview.image != nil)
        #expect(Double(overview.pixels.width * overview.pixels.height) <= CloudBakery.overviewPixels * 1.01)
        var near = base.zoomed(0.1)
        near.centre = field.clearings[0].centre
        let cameras = [
            ("flat", near), ("tilted", near.tipped(55).turned(30)), ("turned round", near.tipped(40).turned(170)),
            ("zoomed out", near.zoomed(0.05)), ("zoomed in", near.zoomed(6).tipped(55).turned(-60)),
        ]
        for (name, camera) in cameras {
            let now = camera.projection
            let placement = try #require(OverviewPlacement(overview: overview.projection, pixels: overview.pixels, now: now, size: camera.size), "\(name)")
            #expect(placement.visible, "\(name)")
            var checked = 0
            for i in 0...6 {
                for j in 0...6 {
                    let s = CGPoint(x: camera.size.width * Double(i) / 6, y: camera.size.height * Double(j) / 6)
                    if now.isFar(s, far: BakeFrame.far) { continue }
                    let ground = camera.ground(s)
                    // Where that ground is in the overview's picture, then where the layers put that.
                    let pixel = overview.projection.point(ground)
                    guard CGRect(origin: .zero, size: overview.pixels).contains(pixel) else { continue }
                    let local = pixel.applying(placement.imageTransform)
                    #expect(close(apply(placement.transform, local), s, within: 0.05), "\(name) at \(s)")
                    #expect(CGRect(origin: .zero, size: placement.windowSize).insetBy(dx: -0.01, dy: -0.01).contains(local), "\(name) at \(s)")
                    checked += 1
                }
            }
            #expect(checked > 0, "\(name)")
        }
        // Soft zoomed in, so the live clouds stand in there; sharp zoomed out.
        let zoomedIn = near.zoomed(20)
        let zoomedOut = near.zoomed(0.05)
        let soft = try #require(OverviewPlacement(overview: overview.projection, pixels: overview.pixels, now: zoomedIn.projection, size: zoomedIn.size))
        let sharp = try #require(OverviewPlacement(overview: overview.projection, pixels: overview.pixels, now: zoomedOut.projection, size: zoomedOut.size))
        #expect(soft.stretch > BakePolicy.overviewStretch)
        #expect(sharp.stretch < BakePolicy.overviewStretch)
        // Looking somewhere else entirely, there's nothing of it to show.
        let away = try #require(OverviewPlacement(overview: overview.projection, pixels: overview.pixels, now: near.pan(50_000, 0).projection, size: near.size))
        #expect(!away.visible)
    }

    /// The overview of a whole suburb (some 8,000 puffs, as Mike's has) with the real
    /// sprites is quick: it stamps each puff from a sprite shrunk to its few pixels.
    /// Drawn from the full-size sprites it took over 2 s in a Debug build in the simulator.
    @Test func theOverviewOfAWholeSuburbIsQuick() throws {
        let test = CloudTests()
        var tiles = Set<Hex>()
        for q in -45...45 {
            for r in -45...45 { tiles.insert(test.hex(q: Int32(q), r: Int32(r))) }
        }
        let field = CloudField(city: test.city(tiles: tiles, visited: [test.hex(q: 0, r: 0), test.hex(q: 3, r: 2)]))
        #expect(field.puffs.count > 5000, "\(field.puffs.count) puffs")
        // The sprites are made once at launch, for the bakes too.
        _ = CloudSprites.sprites(for: "clouds.classic")
        var best = Double.infinity
        var overview: CloudOverview?
        for _ in 0..<3 {
            let made = CloudBakery.overview(field: field, fieldKey: "a", theme: "clouds.classic", clock: 0)
            best = min(best, made.milliseconds)
            overview = made
        }
        let made = try #require(overview)
        print("Overview of \(field.puffs.count) puffs, \(Int(made.pixels.width)) x \(Int(made.pixels.height)) px: best of 3 \(String(format: "%.0f", best)) ms")
        #expect(made.image != nil)
        #expect(Double(made.pixels.width * made.pixels.height) <= CloudBakery.overviewPixels * 1.01)
        // Well under a second even in a Debug build with the suite running in parallel;
        // about 0.3 s on its own there, and a fraction of that on a phone in Release.
        #expect(best < 1000, "took \(best) ms")

        // And it's still the clouds: solid over the middle of the puffs, clear past them.
        let image = try #require(made.image)
        let alphas = Alphas(image)
        let puff = try #require(field.puffs.first { $0.tile.hex == test.hex(q: -20, r: 10) })
        let cloudy = made.projection.point(puff.centre)
        #expect(alphas.at(cloudy.x / made.pixels.width, cloudy.y / made.pixels.height) > 200)
        let clear = made.projection.point(try #require(field.clearings.first).centre)
        #expect(alphas.at(clear.x / made.pixels.width, clear.y / made.pixels.height) < 100)
    }

    // MARK: When to bake

    private func shown(draft: Bool = false, clock: Double = 100, honeycomb: Bool = true) -> BakePolicy.Shown {
        let frame = BakeFrame.around(base.projection, size: base.size, displayScale: 3, draft: draft)
        return BakePolicy.Shown(frame: frame, fieldKey: "a", theme: "clouds.classic", clock: clock, honeycombCurrent: honeycomb)
    }

    private let wanted = BakePolicy.Wanted(fieldKey: "a", theme: "clouds.classic")

    private func decide(
        _ shown: BakePolicy.Shown?, wanted: BakePolicy.Wanted? = nil, fits: Bool = true, exact: Bool = true,
        moving: Bool = false, dragging: Bool = false, clock: Double = 101, drifts: Bool = true, asked: BakePolicy.Asked? = nil,
        flying: Bool = false
    ) -> BakePolicy.Request? {
        BakePolicy.decide(
            shown: shown, wanted: wanted ?? self.wanted, fits: fits, exact: exact, moving: moving,
            dragging: dragging, clock: clock, drifts: drifts, asked: asked, flying: flying
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

    /// While MapKit flies the camera by itself (opening the app on you), nothing's
    /// baked from round it: it'd be far off by the time it was done.
    @Test func nothingsBakedMidFlight() {
        #expect(decide(nil, moving: true, flying: true) == nil)
        #expect(decide(shown(), fits: false, exact: false, moving: true, flying: true) == nil)
        #expect(decide(shown(draft: true), fits: false, exact: false, moving: true, flying: true) == nil)
        // New tiles from the frame on screen are still fine, as they drop straight in.
        let tiles = BakePolicy.Wanted(fieldKey: "b", theme: "clouds.classic")
        #expect(decide(shown(), wanted: tiles, moving: true, flying: true) == .init(frame: .shown, clock: .shown, honeycomb: true))
        #expect(decide(shown(), wanted: tiles, fits: false, moving: true, flying: true) == nil)
        // Under a finger, as before.
        #expect(decide(shown(), fits: false, exact: false, moving: true, dragging: true) == .init(frame: .fresh(draft: true), clock: .shown, honeycomb: true))
    }

    /// Bakes take 1 to 2 s on an iPhone XS Max and up to 2.5 s in a Debug build in the
    /// simulator: none of those is given up on, but one many times slower than the
    /// last is.
    @Test func onlyAStuckBakeIsGivenUpOn() {
        #expect(BakePolicy.giveUp(lastBake: nil) > 2.5)
        #expect(BakePolicy.giveUp(lastBake: 0.2) == BakePolicy.minimumGiveUp)
        #expect(BakePolicy.giveUp(lastBake: 0.2) > 2.5)
        #expect(BakePolicy.giveUp(lastBake: 1.9) > 5)
        #expect(BakePolicy.giveUp(lastBake: 2.5) > 7)
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
        let field = CloudFixtures.clearingField()
        var centred = base.zoomed(0.2)
        centred.centre = field.after.clearings[0].centre
        let frame = BakeFrame.around(centred.projection, size: centred.size, displayScale: 3, draft: false)
        let leaving = field.before.puffs.filter { puff in !field.after.puffs.contains { $0.tile == puff.tile } }
        #expect(!leaving.isEmpty)
        let patch = try #require(CloudBakery.revealPatch(field: field.after, leaving: leaving, frame: frame))
        #expect(frame.rect.contains(patch))
        // On whole pixels of the bake.
        for edge in [patch.minX - frame.rect.minX, patch.minY - frame.rect.minY, patch.width, patch.height] {
            let pixels = Double(edge) * frame.cloudScale
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
        var field = CloudFixtures.clearingField().after
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
        let fields = CloudFixtures.clearingField()
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
            let x = Int((s.x - frame.rect.minX) * frame.cloudScale), y = Int((s.y - frame.rect.minY) * frame.cloudScale)
            let data = image.dataProvider!.data! as Data
            // BGRA, premultiplied: alpha's the fourth byte.
            return Int(data[y * image.bytesPerRow + x * 4 + 3])
        }
        let (before, cloudy) = try bake(fields.before)
        let (after, cleared) = try bake(fields.after)
        #expect(cloudy.width == frame.cloudPixelWidth && cloudy.height == frame.cloudPixelHeight)
        #expect(CloudBakery.honeycomb(before.job) != nil && CloudBakery.honeycomb(after.job) != nil)
        #expect(alpha(cloudy, at: walked) > 240)
        // Only a shadow or two left over the hole.
        #expect(alpha(cleared, at: walked) < alpha(cloudy, at: walked) - 80)
    }

    /// Zoomed in there are streets and a grid: they're in their own sharper picture,
    /// with the same holes, and a drift bake takes them from the last one.
    @Test func theLinesAreBakedOnTheirOwnAndKeptForTheDrift() throws {
        var field = CloudFixtures.clearingField().after
        let walked = field.clearings[0].centre
        var camera = base.zoomed(0.1)
        camera.centre = walked
        field.lines = [CloudField.Line(points: [
            MKMapPoint(x: walked.x - 2000, y: walked.y), MKMapPoint(x: walked.x + 2000, y: walked.y),
        ], kind: .road)]
        field.outline = [[
            MKMapPoint(x: walked.x - 5000, y: walked.y - 5000), MKMapPoint(x: walked.x + 5000, y: walked.y - 5000),
            MKMapPoint(x: walked.x + 5000, y: walked.y + 5000), MKMapPoint(x: walked.x - 5000, y: walked.y + 5000),
        ]]
        let frame = BakeFrame.around(camera.projection, size: camera.size, displayScale: 3, draft: false)
        func job(clock: Double, from: CloudBake? = nil) -> BakeJob {
            BakeJob(
                frame: frame, field: field, fieldKey: "a", theme: "clouds.classic", clock: clock,
                honeycomb: false, walkTiles: [], walkKey: 0, previous: nil, previousKey: nil,
                keptLines: from.map { KeptLines(image: $0.lines) }
            )
        }
        let first = CloudBakery.bake(job(clock: 0))
        let lines = try #require(first.lines)
        #expect(lines.width == frame.pixelWidth && lines.height == frame.pixelHeight)
        #expect(try #require(first.clouds).width == frame.cloudPixelWidth)
        // The street's cut where the tile's been walked, and carries on outside it.
        let alphas = Alphas(lines)
        func onStreet(_ ground: MKMapPoint) -> Int {
            let s = frame.projection.point(ground)
            let y = (s.y - frame.rect.minY) / frame.rect.height
            let x = (s.x - frame.rect.minX) / frame.rect.width
            // Dashes: the most over a dash and its gap.
            return (-12...12).map { alphas.at(x + Double($0) / Double(lines.width), y) }.max() ?? 0
        }
        #expect(onStreet(walked) < 8)
        let radius = field.clearings[0].radius
        #expect(onStreet(MKMapPoint(x: walked.x + radius * 1.5, y: walked.y)) > 60)
        // Drifted on: new clouds, the very same lines.
        let drifted = CloudBakery.bake(job(clock: 100, from: first))
        #expect(drifted.lines === first.lines)
        #expect(drifted.clouds !== first.clouds)
        // And it doesn't hold on to the bake it took them from, or a map left open would
        // keep every drift's clouds for as long as it's open.
        weak var gone: CloudBake?
        var kept = drifted
        autoreleasepool {
            var previous: CloudBake? = CloudBakery.bake(job(clock: 200))
            gone = previous
            kept = CloudBakery.bake(job(clock: 300, from: previous))
            previous = nil
        }
        #expect(gone == nil)
        #expect(kept.lines != nil)
        // Zoomed out far enough there aren't any, and no picture of nothing.
        let far = base.zoomed(40)
        let wide = BakeFrame.around(far.projection, size: far.size, displayScale: 3, draft: false)
        let out = CloudBakery.bake(BakeJob(
            frame: wide, field: field, fieldKey: "a", theme: "clouds.classic", clock: 0,
            honeycomb: false, walkTiles: [], walkKey: 0, previous: nil, previousKey: nil
        ))
        #expect(out.lines == nil)
    }

    /// Small puffs are stamped from sprites no bigger than they need, and big ones from the biggest.
    @Test func spritesAreChosenBySizeOnScreen() throws {
        let sprites = CloudSprites.sprites(for: "clouds.classic")
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 2, y: 2)
        #expect(sprites.level(for: 10, on: context).tops[0].width == 24)
        #expect(sprites.level(for: 40, on: context).tops[0].width == 96)
        #expect(sprites.level(for: 90, on: context).bases[0].width == 192)
        // A little bigger than the next size down still gets the size up.
        #expect(sprites.level(for: 97, on: context).tops[0].width == 384)
        #expect(sprites.level(for: 500, on: context).tops[0].width == 384)
        // The smaller sprites only ever go as big as they started.
        #expect(sprites.level(for: 90, on: context).eraser.width == 128)
        #expect(sprites.level(for: 90, on: context).shadows[0].width == 160)
    }
}
