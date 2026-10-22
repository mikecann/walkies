import MapKit
import SwiftUI

/// Frame times summed up: percentiles by nearest rank, in milliseconds. A hitch is a
/// frame that took more than one and a half refreshes.
nonisolated struct FrameStats: Codable, Equatable, Sendable {
    var frames = 0
    var seconds = 0.0
    var fps = 0.0
    var p50 = 0.0
    var p90 = 0.0
    var p99 = 0.0
    var longest = 0.0
    var hitches = 0

    static let hitchFactor = 1.5

    init() {}

    /// `intervals` between frames and `refresh`, the display's frame interval, in seconds.
    init(intervals: [Double], refresh: Double) {
        guard !intervals.isEmpty else { return }
        let sorted = intervals.sorted()
        frames = sorted.count
        seconds = sorted.reduce(0, +)
        fps = seconds > 0 ? Double(frames) / seconds : 0
        p50 = Self.percentile(sorted, 0.5) * 1000
        p90 = Self.percentile(sorted, 0.9) * 1000
        p99 = Self.percentile(sorted, 0.99) * 1000
        longest = (sorted.last ?? 0) * 1000
        hitches = sorted.filter { $0 > refresh * Self.hitchFactor }.count
    }

    /// The smallest value with at least `p` of them at or below it.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, max(1, rank)) - 1]
    }

    /// Rounded for printing.
    var json: [String: Any] {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return ["frames": frames, "seconds": r(seconds), "fps": r(fps), "p50": r(p50), "p90": r(p90), "p99": r(p99), "max": r(longest), "hitches": hitches]
    }
}

/// `-perfRun`: once the map and clouds are up, flies the camera over the selected place
/// for about 20 seconds (panning slowly and fast, pinching, tilting and turning, at
/// street level and over the whole suburb), times every frame with a display link,
/// and prints one line of JSON to stdout starting `WALKIES_PERF `. Then quits, unless
/// `-perfStay` is also given. Does nothing without `-perfRun`.
final class PerfRun {
    static let requested = LaunchArguments.has("-perfRun")

    struct Camera {
        /// From the middle of the place, in metres.
        var east = 0.0
        var north = 0.0
        var distance: Double
        var pitch: Double
        var heading = 0.0
    }

    struct Segment {
        let name: String
        let duration: Double
        /// Whether it's standing in for a finger on the map.
        var gesture = true
        let camera: (Double) -> Camera
    }

    /// The flight: each segment takes `t` from 0 to 1 and starts where the last ended.
    static func segments(suburb u: Double, pitch p: Double) -> [Segment] {
        let s = 600.0
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        // 0 to 1 and back.
        func wave(_ t: Double) -> Double { (1 - cos(2 * .pi * t)) / 2 }
        func zoom(_ a: Double, _ b: Double, _ f: Double) -> Double { a * pow(b / a, f) }
        let tilted = p > 30 ? 10.0 : 50.0
        return [
            Segment(name: "still_street", duration: 2, gesture: false) { _ in Camera(distance: s, pitch: p) },
            Segment(name: "street_slow_pan", duration: 2.5) { t in Camera(east: 250 * ease(t), north: 150 * ease(t), distance: s, pitch: p) },
            Segment(name: "street_fast_pan", duration: 2.5) { t in Camera(east: 250 - 1400 * wave(t), north: 150 - 500 * wave(t), distance: s, pitch: p) },
            Segment(name: "street_pinch", duration: 3) { t in Camera(east: 250, north: 150, distance: zoom(s, s * 5, wave(t)), pitch: p) },
            Segment(name: "street_tilt", duration: 2.5) { t in Camera(east: 250, north: 150, distance: s, pitch: p + (tilted - p) * wave(t)) },
            Segment(name: "street_rotate", duration: 2.5) { t in Camera(east: 250, north: 150, distance: s, pitch: p, heading: 180 * wave(t)) },
            Segment(name: "zoom_out", duration: 2) { t in Camera(east: 250 * (1 - ease(t)), north: 150 * (1 - ease(t)), distance: zoom(s, u, ease(t)), pitch: p) },
            Segment(name: "suburb_slow_pan", duration: 2.5) { t in Camera(east: 0.2 * u * ease(t), north: 0.1 * u * ease(t), distance: u, pitch: p) },
            Segment(name: "suburb_fast_pan", duration: 2.5) { t in Camera(east: 0.2 * u - 0.8 * u * wave(t), north: 0.1 * u - 0.3 * u * wave(t), distance: u, pitch: p) },
            Segment(name: "suburb_pinch", duration: 2) { t in Camera(east: 0.2 * u, north: 0.1 * u, distance: zoom(u, u * 0.4, wave(t)), pitch: p) },
        ]
    }

    private let handle: MapHandle
    private let model: AppModel

    init(handle: MapHandle, model: AppModel) {
        self.handle = handle
        self.model = model
    }

    private func report(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return }
        // Straight out, as stdout's buffered when it isn't a terminal.
        print("WALKIES_PERF " + line)
        fflush(stdout)
    }

    func run() async {
        // Wait for the map, a place and its clouds.
        var ready: (MKMapView, City)?
        for _ in 0..<240 {
            if let map = handle.map, map.window != nil, map.bounds.width > 0,
               let city = model.selectedCity ?? model.cities.first, !model.cloudField.puffs.isEmpty {
                ready = (map, city)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let (map, city) = ready else {
            report(["error": "no map or place with clouds after 60 s"])
            return
        }
        // Let opening the app's own flight to where you are finish first.
        try? await Task.sleep(for: .seconds(5))

        let points = city.boundary.polygons.flatMap(\.outer).map { MKMapPoint($0.cl) }
        let rect = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 0, height: 0))) }
        let middle = MKMapPoint(x: rect.midX, y: rect.midY)
        // How far back to see the whole place, as fitting it flat finds.
        let pitch = model.tilted3D ? 55.0 : 0
        map.camera = MKMapCamera(lookingAtCenter: middle.coordinate, fromDistance: 2000, pitch: 0, heading: 0)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20), animated: false)
        let suburb = max(1500, map.camera.centerCoordinateDistance)

        let segments = Self.segments(suburb: suburb, pitch: pitch)
        let perMetre = MKMapPointsPerMeterAtLatitude(middle.coordinate.latitude)
        let apply = { (camera: Camera) in
            let centre = MKMapPoint(x: middle.x + camera.east * perMetre, y: middle.y - camera.north * perMetre)
            map.camera = MKMapCamera(lookingAtCenter: centre.coordinate, fromDistance: camera.distance, pitch: camera.pitch, heading: camera.heading)
        }
        apply(segments[0].camera(0))
        // Map tiles and the first clouds in.
        try? await Task.sleep(for: .seconds(4))

        let flight = Flight(segments: segments, handle: handle, apply: apply)
        let results = await flight.fly()

        var segmentJSON: [[String: Any]] = []
        for result in results {
            var fields = FrameStats(intervals: result.intervals, refresh: flight.refresh).json
            fields["name"] = result.name
            fields["bakes"] = result.bakes
            fields["bakeMsAvg"] = result.bakes > 0 ? (result.bakeMilliseconds / Double(result.bakes) * 10).rounded() / 10 : 0
            fields["liveTicks"] = result.liveTicks
            segmentJSON.append(fields)
        }
        let stats = CloudRenderStats.shared
        var machine = utsname()
        uname(&machine)
        let device = withUnsafeBytes(of: machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        report([
            "renderer": CloudRenderer.current.rawValue,
            "device": device,
            "os": UIDevice.current.systemVersion,
            "refreshHz": (1 / flight.refresh).rounded(),
            "screen": [Double(map.bounds.width), Double(map.bounds.height)],
            "scale": Double(map.traitCollection.displayScale),
            "pitch": pitch,
            "suburbDistance": suburb.rounded(),
            "puffs": model.cloudField.puffs.count,
            "segments": segmentJSON,
            "overall": FrameStats(intervals: results.flatMap(\.intervals), refresh: flight.refresh).json,
            "bakes": stats.bakes,
            "draftBakes": stats.drafts,
            "bakeMsAvg": stats.bakes > 0 ? (stats.bakeMilliseconds / Double(stats.bakes) * 10).rounded() / 10 : 0,
            "bakeMsMax": (stats.longestBake * 10).rounded() / 10,
        ])
        guard !LaunchArguments.has("-perfStay") else { return }
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
    }
}

/// Moves the camera along the segments in step with the display, timing each frame.
private final class Flight {
    struct Result {
        var name: String
        var intervals: [Double] = []
        var bakes = 0
        var bakeMilliseconds = 0.0
        var liveTicks = 0
    }

    let segments: [PerfRun.Segment]
    let handle: MapHandle
    let apply: (PerfRun.Camera) -> Void
    /// The display's frame interval.
    private(set) var refresh = 1.0 / 60

    private var link: CADisplayLink?
    private var start: Double?
    private var last: Double?
    private var current = -1
    private var results: [Result] = []
    private var counters = (bakes: 0, milliseconds: 0.0, live: 0)
    private var done: CheckedContinuation<[Result], Never>?

    init(segments: [PerfRun.Segment], handle: MapHandle, apply: @escaping (PerfRun.Camera) -> Void) {
        self.segments = segments
        self.handle = handle
        self.apply = apply
        results = segments.map { Result(name: $0.name) }
    }

    func fly() async -> [Result] {
        await withCheckedContinuation { continuation in
            done = continuation
            let link = CADisplayLink(target: Target(self), selector: #selector(Target.step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private final class Target: NSObject {
        weak var flight: Flight?
        init(_ flight: Flight) { self.flight = flight }
        @objc func step(_ link: CADisplayLink) { flight?.step(link) }
    }

    private func step(_ link: CADisplayLink) {
        refresh = link.duration > 0 ? link.duration : refresh
        let now = link.timestamp
        if let last, current >= 0 { results[current].intervals.append(now - last) }
        last = now
        let start = start ?? now
        self.start = start

        // Where the camera should be when this frame shows.
        var t = link.targetTimestamp - start
        var index = 0
        while index < segments.count, t >= segments[index].duration {
            t -= segments[index].duration
            index += 1
        }
        if index != current {
            if current >= 0 { closeCounters(current) }
            current = index
            openCounters()
            guard index < segments.count else {
                finish()
                return
            }
            handle.simulatedGesture = segments[index].gesture
        }
        let segment = segments[index]
        apply(segment.camera(min(1, t / segment.duration)))
    }

    private func openCounters() {
        let stats = CloudRenderStats.shared
        counters = (stats.bakes, stats.bakeMilliseconds, stats.liveTicks)
    }

    private func closeCounters(_ index: Int) {
        let stats = CloudRenderStats.shared
        results[index].bakes = stats.bakes - counters.bakes
        results[index].bakeMilliseconds = stats.bakeMilliseconds - counters.milliseconds
        results[index].liveTicks = stats.liveTicks - counters.live
    }

    private func finish() {
        link?.invalidate()
        link = nil
        handle.simulatedGesture = false
        done?.resume(returning: results)
        done = nil
    }
}

/// `-perfOverlay`: a small live frame-rate readout over the map.
struct PerfOverlay: View {
    static let requested = LaunchArguments.has("-perfOverlay")

    @State private var meter = FrameMeter()

    var body: some View {
        Text(meter.text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .allowsHitTesting(false)
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
    }
}

@Observable
private final class FrameMeter {
    var text = "–"
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var intervals: [Double] = []
    @ObservationIgnored private var last: Double?
    @ObservationIgnored private var since = 0.0
    @ObservationIgnored private var liveTicks = 0

    private final class Target: NSObject {
        weak var meter: FrameMeter?
        init(_ meter: FrameMeter) { self.meter = meter }
        @objc func step(_ link: CADisplayLink) { meter?.step(link) }
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    private func step(_ link: CADisplayLink) {
        if let last { intervals.append(link.timestamp - last) }
        last = link.timestamp
        if since == 0 { since = link.timestamp }
        guard link.timestamp - since >= 0.5, !intervals.isEmpty else { return }
        let stats = FrameStats(intervals: intervals, refresh: link.duration)
        // How many bakes so far, how many were given up on, and "+live" while the live Canvas is standing in for one.
        let clouds = CloudRenderStats.shared
        var renderer = CloudRenderer.current.rawValue
        if CloudRenderer.current == .baked {
            renderer += " \(clouds.bakes)"
            if clouds.abandoned > 0 { renderer += " (\(clouds.abandoned) stuck)" }
            if clouds.liveTicks != liveTicks { renderer += " +live" }
            liveTicks = clouds.liveTicks
        }
        text = String(format: "%.0f fps  p90 %.1f  max %.0f ms  %d hitch%@  %@", stats.fps, stats.p90, stats.longest, stats.hitches, stats.hitches == 1 ? "" : "es", renderer)
        intervals.removeAll(keepingCapacity: true)
        since = link.timestamp
    }
}
