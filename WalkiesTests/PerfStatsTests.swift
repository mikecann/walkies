import Testing
@testable import Walkies

/// The sums the `-perfRun` harness prints.
struct PerfStatsTests {
    let sixty = 1.0 / 60

    @Test func percentilesAreByNearestRank() {
        // 1 to 100 ms, shuffled.
        let intervals = (1...100).map { Double($0) / 1000 }.shuffled()
        let stats = FrameStats(intervals: intervals, refresh: sixty)
        #expect(stats.frames == 100)
        #expect(abs(stats.p50 - 50) < 1e-9)
        #expect(abs(stats.p90 - 90) < 1e-9)
        #expect(abs(stats.p99 - 99) < 1e-9)
        #expect(abs(stats.longest - 100) < 1e-9)
        #expect(abs(stats.seconds - 5.05) < 1e-9)
        #expect(abs(stats.fps - 100 / 5.05) < 1e-9)
        // Over 25 ms, one and a half 60 Hz frames: 26 to 100.
        #expect(stats.hitches == 75)
    }

    @Test func aSmoothRunHasNoHitches() {
        let stats = FrameStats(intervals: Array(repeating: sixty, count: 600), refresh: sixty)
        #expect(stats.hitches == 0)
        #expect(abs(stats.fps - 60) < 1e-9)
        #expect(abs(stats.p50 - 1000 / 60) < 1e-9)
        #expect(abs(stats.p99 - 1000 / 60) < 1e-9)
        #expect(abs(stats.seconds - 10) < 1e-9)
    }

    @Test func oneDroppedFrameIsOneHitch() {
        // A frame that took two refreshes in a second of otherwise smooth ones.
        var intervals = Array(repeating: sixty, count: 58)
        intervals.append(2 * sixty)
        let stats = FrameStats(intervals: intervals, refresh: sixty)
        #expect(stats.hitches == 1)
        #expect(abs(stats.longest - 2000 / 60) < 1e-9)
        #expect(abs(stats.p50 - 1000 / 60) < 1e-9)
        // 59 frames in a second.
        #expect(abs(stats.fps - 59) < 1e-9)
        // Just under one and a half refreshes isn't one.
        #expect(FrameStats(intervals: [sixty * 1.49], refresh: sixty).hitches == 0)
    }

    @Test func smallSamples() {
        #expect(FrameStats(intervals: [], refresh: sixty) == FrameStats())
        let one = FrameStats(intervals: [0.02], refresh: sixty)
        #expect(one.frames == 1)
        #expect(abs(one.p50 - 20) < 1e-9 && abs(one.p99 - 20) < 1e-9 && abs(one.longest - 20) < 1e-9)
        #expect(FrameStats.percentile([1, 2, 3, 4], 0.5) == 2)
        #expect(FrameStats.percentile([1, 2, 3, 4], 0.51) == 3)
        #expect(FrameStats.percentile([1, 2, 3, 4], 1) == 4)
        #expect(FrameStats.percentile([1, 2, 3, 4], 0) == 1)
    }

    @Test func theJSONIsRoundedToHundredths() {
        let stats = FrameStats(intervals: [1.0 / 3, 1.0 / 3, 1.0 / 3], refresh: sixty)
        let json = stats.json
        #expect(json["p50"] as? Double == 333.33)
        #expect(json["fps"] as? Double == 3)
        #expect(json["hitches"] as? Int == 3)
        #expect(json["frames"] as? Int == 3)
    }

    @Test func theFlightIsAboutTwentySecondsAndJoinsUp() {
        let segments = PerfRun.segments(suburb: 4000, pitch: 55)
        let total = segments.reduce(0) { $0 + $1.duration }
        #expect(total >= 18 && total <= 26)
        // Each segment starts where the last one ended, so nothing jumps.
        for (a, b) in zip(segments, segments.dropFirst()) {
            let end = a.camera(1), start = b.camera(0)
            #expect(abs(end.east - start.east) < 1e-6 && abs(end.north - start.north) < 1e-6, "\(a.name) to \(b.name)")
            #expect(abs(end.distance - start.distance) < 1e-6, "\(a.name) to \(b.name)")
            #expect(abs(end.pitch - start.pitch) < 1e-6 && abs(end.heading - start.heading) < 1e-6, "\(a.name) to \(b.name)")
        }
        let names = Set(segments.map(\.name))
        #expect(names.count == segments.count)
    }
}
