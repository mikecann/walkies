import CoreLocation
import Foundation

nonisolated struct TrackPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    /// Seconds since 1970.
    var time: Double
    /// Horizontal accuracy in metres. Negative means invalid.
    var accuracy: Double
    /// Speed from the GPS itself (Doppler), in m/s, when it had one. Far steadier
    /// than working it out from the distance between two fixes.
    var speed: Double?
    /// The motion chip thought you were on a bike or in a car at the time.
    var wheels: Bool?
    /// The motion chip thought you were standing still.
    var still: Bool?

    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

nonisolated extension TrackPoint {
    init(_ location: CLLocation) {
        self.init(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            time: location.timestamp.timeIntervalSince1970,
            accuracy: location.horizontalAccuracy,
            speed: location.speed >= 0 ? location.speed : nil
        )
    }
}

nonisolated struct Walk: Codable, Identifiable, Sendable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    /// Every fix we got, good or bad. Coverage is always recomputed from these,
    /// so changing the filters or adding a city later uses the full history.
    var points: [TrackPoint] = []
    var distance: Double = 0
    var newTiles = 0
    /// Recorded by always-on mode rather than started with the button. Optional so
    /// walks saved before always-on existed still load.
    var automatic: Bool?

    var isAutomatic: Bool { automatic == true }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}

/// Turns a stream of GPS fixes into the spots we count as "been there".
nonisolated struct CoverageTracer: Sendable {
    struct Step {
        var samples: [Coordinate]
        var distance: Double
        static let none = Step(samples: [], distance: 0)
    }

    /// Fixes less accurate than this (metres) are ignored.
    static let maxAccuracy = 30.0
    /// Faster than a jog (m/s, about 12 km/h) doesn't count, so cycling
    /// and driving don't uncover anything. Checked against the GPS's own speed reading.
    static let maxSpeed = 3.3
    /// Slower than this (m/s) by the GPS's own speed reading is standing about, not walking.
    static let minSpeed = 0.4
    /// You have to get at least this far (metres) from the last counted spot, and further
    /// than the GPS's own error, before it counts. Otherwise the GPS wobbling round one
    /// spot indoors adds up to a walk.
    static let minStep = 8.0
    /// Seconds since the last counted spot after which a fix with no speed reading is
    /// treated as drift.
    static let maxDriftGap = 60.0
    /// The same speed check between counted spots is noisier, so it gets some slack.
    static let maxSpeedBetweenFixes = 5.0
    /// Don't join the dots across a GPS dropout longer than this (metres).
    static let maxGap = 150.0
    /// Spacing (metres) of the points we sample between fixes.
    static let spacing = 10.0

    /// The last spot that counted. New fixes are measured from here, not from the
    /// previous fix, so lots of tiny wobbles never add up.
    private var anchor: TrackPoint?

    mutating func add(_ point: TrackPoint) -> Step {
        guard point.accuracy >= 0, point.accuracy <= Self.maxAccuracy else { return .none }
        // On a bike or in a car: start again from scratch once you're back on foot.
        if point.wheels == true || (point.speed ?? 0) > Self.maxSpeed {
            anchor = nil
            return .none
        }
        // Standing still: wait, keeping the anchor where it was.
        if point.still == true { return .none }
        if let speed = point.speed, speed < Self.minSpeed { return .none }
        // A spot only counts once you've walked on from somewhere that counted, so the
        // first fix after launch or a GPS jump can't sneak a tile in.
        guard let prev = anchor else {
            anchor = point
            return .none
        }

        let d = prev.coordinate.distance(to: point.coordinate)
        if d < max(Self.minStep, point.accuracy) { return .none }
        anchor = point
        let dt = point.time - prev.time
        // Creeping that far over minutes with no speed reading is the GPS drifting, not
        // walking: walking gives a fix every second or two.
        if point.speed == nil, dt > Self.maxDriftGap { return .none }
        if dt > 0, d / dt > Self.maxSpeedBetweenFixes { return .none }
        if d > Self.maxGap { return .none }

        let n = max(1, Int((d / Self.spacing).rounded(.up)))
        let samples = (1...n).map { prev.coordinate.lerp(to: point.coordinate, Double($0) / Double(n)) }
        return Step(samples: samples, distance: d)
    }

    /// How far these points really walked, by the same rules.
    static func distance(for points: [TrackPoint]) -> Double {
        var tracer = CoverageTracer()
        return points.reduce(0) { $0 + tracer.add($1).distance }
    }

    static func samples(for points: [TrackPoint]) -> [Coordinate] {
        var tracer = CoverageTracer()
        return points.flatMap { tracer.add($0).samples }
    }
}
