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
    /// Faster than a jog with the dog (m/s, about 12 km/h) doesn't count, so cycling
    /// and driving don't uncover anything. Checked against the GPS's own speed reading.
    static let maxSpeed = 3.3
    /// The same check between two fixes is noisier (a couple of metres of jitter over
    /// a one-second gap looks like a sprint), so it gets some slack.
    static let maxSpeedBetweenFixes = 5.0
    /// Don't join the dots across a GPS dropout longer than this (metres).
    static let maxGap = 150.0
    /// Spacing (metres) of the points we sample between fixes.
    static let spacing = 10.0

    private var last: TrackPoint?

    mutating func add(_ point: TrackPoint) -> Step {
        guard point.accuracy >= 0, point.accuracy <= Self.maxAccuracy else { return .none }
        defer { last = point }
        if point.wheels == true { return .none }
        if let speed = point.speed, speed > Self.maxSpeed { return .none }
        // A spot only counts once two on-foot fixes in a row agree, so the first fix
        // after launch or after a GPS jump can't sneak a tile in from a car seat.
        guard let prev = last else { return .none }

        let d = prev.coordinate.distance(to: point.coordinate)
        let dt = point.time - prev.time
        if dt > 0, d / dt > Self.maxSpeedBetweenFixes { return .none }
        if d > Self.maxGap { return .none }

        let n = max(1, Int((d / Self.spacing).rounded(.up)))
        let samples = (1...n).map { prev.coordinate.lerp(to: point.coordinate, Double($0) / Double(n)) }
        return Step(samples: samples, distance: d)
    }

    static func samples(for points: [TrackPoint]) -> [Coordinate] {
        var tracer = CoverageTracer()
        return points.flatMap { tracer.add($0).samples }
    }
}
