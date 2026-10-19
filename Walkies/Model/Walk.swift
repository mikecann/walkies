import CoreLocation
import Foundation

nonisolated struct TrackPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    /// Seconds since 1970.
    var time: Double
    /// Horizontal accuracy in metres. Negative means invalid.
    var accuracy: Double

    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

nonisolated extension TrackPoint {
    init(_ location: CLLocation) {
        self.init(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            time: location.timestamp.timeIntervalSince1970,
            accuracy: location.horizontalAccuracy
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
    /// Faster than a jog (m/s) doesn't count, so driving home doesn't uncover anything.
    static let maxSpeed = 4.5
    /// Don't join the dots across a GPS dropout longer than this (metres).
    static let maxGap = 150.0
    /// Spacing (metres) of the points we sample between fixes.
    static let spacing = 10.0

    private var last: TrackPoint?

    mutating func add(_ point: TrackPoint) -> Step {
        guard point.accuracy >= 0, point.accuracy <= Self.maxAccuracy else { return .none }
        defer { last = point }
        guard let prev = last else { return Step(samples: [point.coordinate], distance: 0) }

        let d = prev.coordinate.distance(to: point.coordinate)
        let dt = point.time - prev.time
        if dt > 0, d / dt > Self.maxSpeed { return .none }
        if d > Self.maxGap { return Step(samples: [point.coordinate], distance: 0) }

        let n = max(1, Int((d / Self.spacing).rounded(.up)))
        let samples = (1...n).map { prev.coordinate.lerp(to: point.coordinate, Double($0) / Double(n)) }
        return Step(samples: samples, distance: d)
    }

    static func samples(for points: [TrackPoint]) -> [Coordinate] {
        var tracer = CoverageTracer()
        return points.flatMap { tracer.add($0).samples }
    }
}
