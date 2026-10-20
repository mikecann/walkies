import MapKit
import SwiftUI

/// The end-of-walk celebration. Your walk plays back over the map: the route draws
/// itself, the clouds clear tile by tile with a pop and a puff of sparkles, and it
/// stops for a moment on any secret you found. Then a summary of what the walk did
/// for each place, and roughly how many more it'll take to finish. Rewatched from
/// history it's just the walk: no rewards, and nothing changes.
struct CelebrationView: View {
    let recap: WalkRecap
    /// Your other places, unchanged by this walk, so they're still under cloud.
    let others: [City]
    let tilted: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player: ReplayPlayer
    @State private var handle = MapHandle()
    @State private var openSecret: LoreEntry?
    @State private var showingProgress = false
    /// You've moved the map yourself, so offer to put it back on the walk.
    @State private var moved = false
    @State private var recentre = 0

    init(recap: WalkRecap, others: [City], tilted: Bool) {
        self.recap = recap
        self.others = others
        self.tilted = tilted
        _player = State(initialValue: ReplayPlayer(recap: recap, others: others))
    }

    var body: some View {
        ZStack {
            ReplayMap(recap: recap, tilted: tilted, handle: handle, recentre: recentre) { moved = true }
                .overlay { CloudLayer(field: player.field, key: player.fieldKey, handle: handle) }
                .overlay { ReplayEffects(recap: recap, player: player, handle: handle, style: model.equipped[.celebration]) }
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    tileCounter
                    clock
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        if player.phase == .replay {
                            Button("Skip") { player.skip() }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .stickerCard(in: .capsule)
                        }
                        if moved {
                            HexBadge(icon: .symbol("scope"), fill: .badgeTeal, label: "Back to the walk") {
                                moved = false
                                recentre += 1
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal)
                Spacer()
            }

            if let secret = player.showingSecret {
                SecretPop(entry: secret)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }

            if player.phase == .summary {
                VStack {
                    Spacer()
                    SummaryCard(
                        recap: recap, endingXP: model.xp,
                        hasReward: !recap.isRewatch && !model.pendingPicks.isEmpty,
                        onReward: { showingProgress = true },
                        onSecret: { openSecret = $0 }, onReplay: { player.replay() }, onDone: { dismiss() }
                    )
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.cream)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.showingSecret?.id)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: player.phase)
        .animation(.snappy, value: moved)
        .task { await player.run() }
        .sheet(isPresented: $showingProgress) {
            ProgressionSheet(initialSection: .level)
        }
        .sheet(item: $openSecret) { entry in
            LoreCardView(entry: entry, foundAt: nil)
        }
    }

    private var tileCounter: some View {
        HStack(spacing: 6) {
            Text("+\(player.tilesShown)")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color.walkiesOrange)
                .contentTransition(.numericText(value: Double(player.tilesShown)))
            Text(player.tilesShown == 1 ? "tile" : "tiles")
                .font(.headline)
                .foregroundStyle(Color.ink.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .stickerCard(in: .capsule)
        .scaleEffect(player.bump ? 1.12 : 1)
        .animation(.snappy(duration: 0.15), value: player.tilesShown)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: player.bump)
    }

    /// How long you'd been out at the point the route's drawn to, racing up to the
    /// walk's full time.
    private var clock: some View {
        Text(Format.duration(player.elapsed))
            .font(.system(.title2, design: .rounded, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .stickerCard(in: .capsule)
            .accessibilityLabel("Time walked")
    }
}

// MARK: The player

/// Runs the replay's clock: where along the route it's got, which tiles have popped,
/// which secret is showing, and which step of the clouds to draw.
@MainActor
@Observable
final class ReplayPlayer {
    enum Phase { case replay, summary }

    struct Burst: Identifiable {
        enum Kind { case tile, secret }
        let id = UUID()
        let kind: Kind
        let coordinate: Coordinate?
        let start: Date
        let seed: UInt64
    }

    private(set) var phase = Phase.replay
    private(set) var progress = 0.0
    private(set) var tilesShown = 0
    private(set) var showingSecret: LoreEntry?
    private(set) var bursts: [Burst] = []
    private(set) var field: CloudField
    private(set) var fieldKey = "replay-0"
    /// Flips on each pop, to nudge the counter.
    private(set) var bump = false

    @ObservationIgnored private let recap: WalkRecap
    @ObservationIgnored private let others: [City]
    @ObservationIgnored private var fields: [CloudField] = []
    @ObservationIgnored private var cuts: [Int] = []
    @ObservationIgnored private var nextReveal = 0
    @ObservationIgnored private var nextSecret = 0
    @ObservationIgnored private var pausedUntil = Date.distantPast
    @ObservationIgnored private var combo = 0
    @ObservationIgnored private var lastPop = Date.distantPast
    @ObservationIgnored private var lastHaptic = Date.distantPast
    @ObservationIgnored private var generation = 0

    /// Seconds for the route to draw: 5 for every 10 minutes walked. At least 2, so a
    /// short walk is still watchable, and at most 30, so a long one doesn't drag.
    var duration: Double { min(30, max(2, recap.walk.duration / 600 * 5)) }

    /// Time into the walk at the replay's current point.
    var elapsed: TimeInterval { recap.elapsed(at: progress) }

    init(recap: WalkRecap, others: [City]) {
        self.recap = recap
        self.others = others
        field = CloudField(cities: others + recap.before)
    }

    /// Plays it through. Stops early if `skip` or `replay` are called.
    func run() async {
        SoundFX.shared.prepare()
        generation += 1
        let thisRun = generation
        await prepareClouds()
        try? await Task.sleep(for: .seconds(0.8))
        var last = Date.now
        while thisRun == generation, phase == .replay {
            let now = Date.now
            let dt = now.timeIntervalSince(last)
            last = now
            if now >= pausedUntil {
                if showingSecret != nil { showingSecret = nil }
                progress = min(1, progress + dt / duration)
                fire(upTo: progress, at: now)
                if progress >= 1, nextSecret >= recap.secrets.count {
                    try? await Task.sleep(for: .seconds(0.6))
                    guard thisRun == generation else { return }
                    finish()
                    return
                }
            }
            bursts.removeAll { now.timeIntervalSince($0.start) > 2.5 }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func skip() {
        generation += 1
        progress = 1
        nextReveal = recap.reveals.count
        nextSecret = recap.secrets.count
        tilesShown = recap.reveals.count
        showingSecret = nil
        if let last = fields.last { show(step: fields.count - 1, last) }
        finish()
    }

    func replay() {
        generation += 1
        phase = .replay
        progress = 0
        nextReveal = 0
        nextSecret = 0
        tilesShown = 0
        combo = 0
        bursts = []
        pausedUntil = .distantPast
        if let first = fields.first { show(step: 0, first) }
        Task { await run() }
    }

    private func finish() {
        phase = .summary
        bursts.append(Burst(kind: .secret, coordinate: nil, start: .now, seed: 42_791))
        SoundFX.shared.play(.fanfare)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func fire(upTo progress: Double, at now: Date) {
        while nextReveal < recap.reveals.count, recap.reveals[nextReveal].at <= progress {
            let reveal = recap.reveals[nextReveal]
            nextReveal += 1
            tilesShown = nextReveal
            bump.toggle()
            combo = now.timeIntervalSince(lastPop) < 0.6 ? combo + 1 : 0
            lastPop = now
            SoundFX.shared.play(.pop(combo))
            if now.timeIntervalSince(lastHaptic) > 0.07 {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                lastHaptic = now
            }
            bursts.append(Burst(kind: .tile, coordinate: reveal.coordinate, start: now, seed: UInt64(nextReveal)))
            if let step = cuts.lastIndex(where: { $0 <= nextReveal }), step < fields.count, "replay-\(step)" != fieldKey {
                show(step: step, fields[step])
            }
        }
        if nextSecret < recap.secrets.count, recap.secrets[nextSecret].at <= progress {
            let secret = recap.secrets[nextSecret]
            nextSecret += 1
            showingSecret = secret.entry
            pausedUntil = now.addingTimeInterval(2.4)
            SoundFX.shared.play(.chime)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            bursts.append(Burst(kind: .secret, coordinate: nil, start: now, seed: UInt64(nextSecret) &* 7919))
        }
    }

    private func show(step: Int, _ next: CloudField) {
        field = next
        fieldKey = "replay-\(step)"
    }

    /// The clouds at a dozen or so points along the walk, worked out off the main
    /// thread up front so the replay doesn't stutter.
    private func prepareClouds() async {
        guard fields.isEmpty else { return }
        let recap = recap, others = others
        let steps = max(1, min(recap.reveals.count, 14))
        let cuts = (0...steps).map { Int((Double($0) / Double(steps) * Double(recap.reveals.count)).rounded()) }
        self.cuts = cuts
        fields = await Task.detached(priority: .userInitiated) {
            cuts.map { cut in
                let shown = recap.reveals.prefix(cut)
                let cities = recap.before.map { city -> City in
                    var city = city
                    city.visited.formUnion(shown.filter { $0.place == city.id }.map(\.hex))
                    return city
                }
                return CloudField(cities: others + cities)
            }
        }.value
        if let first = fields.first { show(step: 0, first) }
    }
}

// MARK: The map

/// A satellite map framed on the walk, for the replay to play over. You can pan,
/// pinch and turn it; it only moves by itself when `recentre` changes.
private struct ReplayMap: UIViewRepresentable {
    let recap: WalkRecap
    let tilted: Bool
    let handle: MapHandle
    var recentre: Int
    let onUserMove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: tilted ? .realistic : .flat)
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        handle.map = map
        context.coordinator.recentre = recentre
        // Wait for the map to have its real size before framing the walk.
        DispatchQueue.main.async { frame(map, animated: false) }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.handle = handle
        context.coordinator.onUserMove = onUserMove
        if recentre != context.coordinator.recentre {
            context.coordinator.recentre = recentre
            frame(map, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var recentre = 0
        weak var handle: MapHandle?
        var onUserMove: () -> Void = {}

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let touched = mapView.subviews.first?.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
            // Every frame while it moves, so the clouds stay stuck to the ground.
            handle?.moving = true
            if touched { onUserMove() }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            handle?.moving = false
        }
    }

    private func frame(_ map: MKMapView, animated: Bool) {
        let points = recap.route.isEmpty ? recap.walk.points.map(\.coordinate) : recap.route
        guard let first = points.first else { return }
        var rect = MKMapRect(origin: MKMapPoint(first.cl), size: MKMapSize(width: 0, height: 0))
        for point in points { rect = rect.union(MKMapRect(origin: MKMapPoint(point.cl), size: MKMapSize(width: 0, height: 0))) }
        // At least about 400 m across, so a short walk isn't zoomed right in.
        let minimum = 400 * MKMapPointsPerMeterAtLatitude(first.lat)
        rect = rect.insetBy(dx: -max(0, minimum - rect.width) / 2, dy: -max(0, minimum - rect.height) / 2)
        let padding = UIEdgeInsets(top: 130, left: 40, bottom: 280, right: 40)
        let start = map.camera.copy() as? MKMapCamera
        // Fit from flat and facing north, so a camera you've tilted or turned doesn't skew it.
        map.camera = MKMapCamera(lookingAtCenter: map.centerCoordinate, fromDistance: map.camera.centerCoordinateDistance, pitch: 0, heading: 0)
        map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        let fitted = map.camera
        let target = MKMapCamera(lookingAtCenter: fitted.centerCoordinate, fromDistance: fitted.centerCoordinateDistance, pitch: tilted ? 45 : 0, heading: 0)
        if animated, let start { map.camera = start }
        map.setCamera(target, animated: animated)
    }
}

// MARK: The effects

/// The route drawing itself, a walker at its head, and the bursts: sparkles where a
/// tile clears, confetti for a secret.
private struct ReplayEffects: View {
    let recap: WalkRecap
    let player: ReplayPlayer
    let handle: MapHandle
    let style: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let teal = Color(red: 0.16, green: 0.72, blue: 0.78)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                guard let map = handle.map else { return }
                let now = timeline.date
                drawRoute(in: &context, map: map)
                for burst in player.bursts {
                    let t = now.timeIntervalSince(burst.start)
                    switch burst.kind {
                    case .tile:
                        guard let coordinate = burst.coordinate else { continue }
                        sparkles(in: &context, at: map.convert(coordinate.cl, toPointTo: map), t: t, seed: burst.seed)
                    case .secret:
                        guard !reduceMotion else { continue }
                        switch style {
                        case "celebration.bubbles": bubbles(in: &context, size: size, t: t, seed: burst.seed)
                        case "celebration.fireworks": fireworks(in: &context, size: size, t: t, seed: burst.seed)
                        default: confetti(in: &context, size: size, t: t, seed: burst.seed)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawRoute(in context: inout GraphicsContext, map: MKMapView) {
        let route = recap.route
        guard route.count > 1 else { return }
        let end = player.progress * Double(route.count - 1)
        let whole = Int(end)
        var path = Path()
        path.move(to: map.convert(route[0].cl, toPointTo: map))
        for i in stride(from: 1, through: min(whole, route.count - 1), by: 1) {
            path.addLine(to: map.convert(route[i].cl, toPointTo: map))
        }
        var head = map.convert(route[min(whole, route.count - 1)].cl, toPointTo: map)
        if whole < route.count - 1 {
            let a = head, b = map.convert(route[whole + 1].cl, toPointTo: map)
            let f = end - Double(whole)
            head = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            path.addLine(to: head)
        }
        context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(Self.teal), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        if player.phase == .replay {
            context.fill(Path(ellipseIn: CGRect(x: head.x - 10, y: head.y - 10, width: 20, height: 20)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: head.x - 6.5, y: head.y - 6.5, width: 13, height: 13)), with: .color(.walkiesOrange))
        }
    }

    /// A puff of white cloud bits and orange and gold sparks flying out from a tile.
    private func sparkles(in context: inout GraphicsContext, at origin: CGPoint, t: Double, seed: UInt64) {
        let life = 0.9
        guard t < life else { return }
        var rng = SplitMix64(seed: seed &* 2_654_435_761)
        let fade = 1 - t / life
        // A quick ring expanding out from the tile.
        let ring = 10 + 70 * (1 - pow(1 - t / life, 3))
        context.stroke(
            Path(ellipseIn: CGRect(x: origin.x - ring, y: origin.y - ring * 0.7, width: ring * 2, height: ring * 1.4)),
            with: .color(.white.opacity(0.7 * fade)), lineWidth: 3 * fade
        )
        for i in 0..<14 {
            let angle = rng.unit() * 2 * .pi
            let speed = 50 + rng.unit() * 90
            let x = origin.x + cos(angle) * speed * t
            let y = origin.y + sin(angle) * speed * t * 0.75 + 40 * t * t
            let r = (i < 6 ? 5 + rng.unit() * 4 : 2.5 + rng.unit() * 2.5) * (0.6 + 0.4 * fade)
            let colour: Color = i < 6 ? .white : (i % 2 == 0 ? .walkiesOrange : Color(red: 1, green: 0.82, blue: 0.3))
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(colour.opacity(fade)))
        }
    }

    /// Soft bubbles drift up, then leave a brief expanding ring as they pop.
    private func bubbles(in context: inout GraphicsContext, size: CGSize, t: Double, seed: UInt64) {
        guard t >= 0, t < 2.5 else { return }
        var rng = SplitMix64(seed: seed)
        let colours: [Color] = [.white, .badgeTeal, .badgeGreen, .pink]
        for i in 0..<30 {
            let delay = rng.unit() * 0.55
            let life = 1.1 + rng.unit() * 0.85
            let age = t - delay
            let x = size.width * rng.unit() + sin(age * 2 + Double(i)) * 18
            let bottom = size.height * (0.75 + rng.unit() * 0.2)
            let speed = 100 + rng.unit() * 150
            let radius = 7 + rng.unit() * 18
            guard age >= 0, age < life + 0.18 else { continue }
            let popping = max(0, (age - life) / 0.18)
            let r = radius * (1 + popping * 0.5)
            let y = bottom - speed * min(age, life)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            let colour = colours[i % colours.count]
            let fade = min(1, age * 6) * (1 - popping)
            if popping == 0 {
                context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(0.16 * fade)))
                context.fill(Path(ellipseIn: CGRect(x: x - r * 0.45, y: y - r * 0.5, width: r * 0.4, height: r * 0.25)), with: .color(.white.opacity(0.65 * fade)))
            }
            context.stroke(Path(ellipseIn: rect), with: .color(colour.opacity(0.65 * fade)), lineWidth: 1.5)
        }
    }

    /// Three staggered bursts, with short glowing trails falling under gravity.
    private func fireworks(in context: inout GraphicsContext, size: CGSize, t: Double, seed: UInt64) {
        guard t >= 0, t < 2.5 else { return }
        var rng = SplitMix64(seed: seed)
        let colours: [Color] = [.walkiesOrange, .badgeTeal, .pink, .yellow, .white]
        for burst in 0..<3 {
            let origin = CGPoint(x: size.width * (0.2 + Double(burst) * 0.3), y: size.height * (0.2 + rng.unit() * 0.2))
            let age = t - Double(burst) * 0.35
            for i in 0..<32 {
                let angle = Double(i) / 32 * 2 * .pi + rng.unit() * 0.1
                let speed = 70 + rng.unit() * 140
                guard age >= 0, age < 1.5 else { continue }
                let fade = min(1, age * 12) * max(0, 1 - age / 1.5)
                func point(_ time: Double) -> CGPoint {
                    CGPoint(x: origin.x + cos(angle) * speed * time,
                            y: origin.y + sin(angle) * speed * time + 70 * time * time)
                }
                var trail = Path()
                trail.move(to: point(max(0, age - 0.08)))
                trail.addLine(to: point(age))
                context.stroke(trail, with: .color(colours[(i + burst) % colours.count].opacity(fade)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }

    /// Confetti thrown up from the bottom of the screen and fluttering down.
    private func confetti(in context: inout GraphicsContext, size: CGSize, t: Double, seed: UInt64) {
        let life = 2.4
        guard t < life else { return }
        var rng = SplitMix64(seed: seed)
        let colours: [Color] = [.walkiesOrange, Color(red: 1, green: 0.82, blue: 0.3), Self.teal, .badgeGreen, Color(red: 0.95, green: 0.45, blue: 0.6), .white]
        let fade = min(1, (life - t) / 0.5)
        for i in 0..<60 {
            let fromLeft = i % 2 == 0
            let startX = fromLeft ? size.width * 0.15 : size.width * 0.85
            let angle = (fromLeft ? -1.2 : -1.94) + (rng.unit() - 0.5) * 0.9
            let speed = 520 + rng.unit() * 380
            let x = startX + cos(angle) * speed * t
            let y = size.height * 0.78 + sin(angle) * speed * t + 520 * t * t
            let spin = rng.unit() * 10 * t
            var piece = context
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(spin))
            piece.fill(Path(CGRect(x: -5, y: -3, width: 10, height: 6)), with: .color(colours[Int(rng.next() % UInt64(colours.count))].opacity(fade)))
        }
    }
}

/// A found secret, held up big with a slow sunburst behind it.
private struct SecretPop: View {
    let entry: LoreEntry
    @State private var spin = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: (0..<16).map { $0 % 2 == 0 ? Color(red: 1, green: 0.85, blue: 0.4).opacity(0.55) : .clear },
                        center: .center
                    ))
                    .frame(width: 300, height: 300)
                    .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 40, endRadius: 150))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: spin)
                StickerArt(entry: entry, size: 170)
            }
            VStack(spacing: 4) {
                Text("Secret found")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.burnt)
                Text(entry.title)
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .stickerCard(in: .rect(cornerRadius: 20))
        }
        .padding(30)
        .onAppear { spin = true }
    }
}

// MARK: The summary

private struct SummaryCard: View {
    let recap: WalkRecap
    let endingXP: Int
    let hasReward: Bool
    let onReward: () -> Void
    let onSecret: (LoreEntry) -> Void
    let onReplay: () -> Void
    let onDone: () -> Void

    @State private var counted = 0
    @State private var countedShells = 0
    @State private var filled = false
    @State private var xpLevel = 1
    @State private var xpFill = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(maxHeight: 600)
        .stickerCard(in: .rect(cornerRadius: 28))
        .padding(12)
        .task { await countUp() }
    }

    private var content: some View {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(recap.newTiles == 0 ? "Walk done" : "+\(counted) new \(recap.newTiles == 1 ? "tile" : "tiles")")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(counted)))
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 0) {
                    stat(Format.distance(recap.walk.distance), "Distance")
                    stat(Format.duration(recap.walk.duration), "Time")
                    stat("\(recap.secrets.count)", recap.secrets.count == 1 ? "Secret" : "Secrets")
                }

                if !recap.isRewatch {
                    progressionSummary
                }

                if !recap.secrets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(recap.secrets, id: \.entry.id) { secret in
                                Button { onSecret(secret.entry) } label: {
                                    VStack(spacing: 4) {
                                        StickerArt(entry: secret.entry, size: 72)
                                        Text(secret.entry.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.ink)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .frame(width: 96)
                                    }
                                }
                                .buttonStyle(PressScale())
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }

                ForEach(recap.places) { place in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(place.name).font(.headline)
                            Spacer()
                            Text((filled ? place.after : place.before).percentText)
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Color.walkiesOrange)
                                .contentTransition(.numericText())
                        }
                        ProgressBar(value: filled ? place.after : place.before)
                        Text("+\(String(format: "%.1f", (place.after - place.before) * 100))% this walk · \(place.tilesLeft) tiles left")
                            .font(.caption)
                            .foregroundStyle(Color.ink.opacity(0.6))
                    }
                }

                if !recap.isRewatch, let prediction = recap.prediction {
                    VStack(spacing: 4) {
                        Text("About \(prediction.walks) more \(prediction.walks == 1 ? "walk" : "walks") like these to finish \(prediction.place)")
                            .font(.subheadline.weight(.semibold))
                        if let weeks = prediction.weeks, let perWeek = prediction.walksPerWeek {
                            Text("At your pace of about \(Int(perWeek.rounded())) a week, that's \(Self.weeksText(weeks)).")
                                .font(.footnote)
                                .foregroundStyle(Color.ink.opacity(0.65))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.sand.opacity(0.5), in: .rect(cornerRadius: 16))
                }

                HStack(spacing: 12) {
                    Button(action: onReplay) {
                        Label("Watch again", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                    }
                    .buttonStyle(StickerButtonStyle(fill: .white, foreground: .ink))
                    Button("Done", action: onDone)
                        .buttonStyle(StickerButtonStyle())
                }
            }
            .padding(20)
    }

    private var headline: String {
        if recap.newTiles == 0 { return "No new tiles this time. Next time, try a street you haven't been down yet." }
        if recap.isBest { return "Your best walk yet. That's a lot of sky cleared." }
        if !recap.secrets.isEmpty { return "And you turned up \(recap.secrets.count == 1 ? "a secret" : "some secrets") on the way." }
        if recap.newTiles >= 30 { return "What a haul. A big chunk of cloud gone." }
        return "Nice one. A few more clouds gone."
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Color.ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private static func weeksText(_ weeks: Double) -> String {
        if weeks < 1.5 { return "about a week" }
        if weeks < 9 { return "about \(Int(weeks.rounded())) weeks" }
        let months = weeks / 4.35
        return months < 1.5 ? "about a month" : "about \(Int(months.rounded())) months"
    }

    private var progressionSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShellBalance(balance: countedShells, prefix: "+")
                    .contentTransition(.numericText(value: Double(countedShells)))
                Spacer()
                Text("+\(recap.xp) XP").font(.subheadline.weight(.bold))
            }
            HStack {
                Text("Level \(xpLevel)").font(.headline)
                Spacer()
                Text("\(endingXP) total XP").font(.caption)
            }
            ProgressBar(value: xpFill)
                .transaction { transaction in
                    // Match the staged fill's duration instead of the bar's default spring.
                    if !transaction.disablesAnimations {
                        transaction.animation = .easeOut(duration: xpAnimationDuration)
                        transaction.disablesAnimations = true
                    }
                }
                .accessibilityLabel("Level \(xpLevel) progress")
                .accessibilityValue("\(Int(xpFill * 100)) percent")
            ForEach(Array(recap.questProgress.enumerated()), id: \.offset) { _, quest in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: filled && quest.completed ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(filled ? Color.badgeTeal : Color.ink.opacity(0.4))
                        .symbolEffect(.bounce, value: filled)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(quest.kind.name).font(.caption.weight(.semibold))
                        Text(QuestProgressText.value(filled ? quest.after : quest.before, kind: quest.kind))
                            .font(.caption2).foregroundStyle(Color.ink.opacity(0.65))
                        ProgressBar(value: min(1, (filled ? quest.after : quest.before) / quest.target))
                    }
                    if filled && quest.completed { Text("+40 shells").font(.caption.weight(.semibold)) }
                }
            }
            if hasReward {
                Button("Level up, choose a reward", action: onReward)
                    .buttonStyle(StickerButtonStyle())
            }
        }
        .padding(12)
        .background(Color.sand.opacity(0.35), in: .rect(cornerRadius: 16))
    }

    private var xpAnimationDuration: Double {
        let count = LevelMeter.fills(from: max(0, endingXP - recap.xp), to: endingXP).count
        return reduceMotion ? 0 : min(0.65, 1.8 / Double(count))
    }

    /// Count tiles and shells together, then fill each level crossed by this walk.
    /// A rewatch only counts the tiles.
    private func countUp() async {
        let before = max(0, endingXP - recap.xp)
        let meter = LevelMeter(xp: before)
        xpLevel = meter.level
        xpFill = meter.fraction
        let total = max(recap.newTiles, recap.shells)
        let steps = reduceMotion ? 1 : min(max(total, 1), 30)
        for i in 1...steps {
            do { try await Task.sleep(for: .milliseconds(max(18, 700 / steps))) } catch { return }
            withAnimation(.snappy(duration: 0.1)) {
                counted = Int(Double(recap.newTiles) * Double(i) / Double(steps))
                countedShells = Int(Double(recap.shells) * Double(i) / Double(steps))
            }
            if total > 0, i % 2 == 0 || steps == 1 { SoundFX.shared.play(.tick) }
        }
        withAnimation(.easeOut(duration: 0.9)) { filled = true }
        guard !recap.isRewatch else { return }
        let fills = LevelMeter.fills(from: before, to: endingXP)
        let duration = xpAnimationDuration
        for fill in fills {
            guard !Task.isCancelled else { return }
            // Reset without animating backwards when the previous level filled up.
            var reset = Transaction(animation: nil)
            reset.disablesAnimations = true
            withTransaction(reset) { xpLevel = fill.level; xpFill = fill.from }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            withAnimation(.easeOut(duration: duration)) { xpFill = fill.to }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
        }
    }
}
