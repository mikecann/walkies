import Foundation
import Testing
@testable import Walkies

struct WalkRecapTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func walk(daysAgo: Double, tiles: Int, metres: Double = 2000) -> Walk {
        let start = now.addingTimeInterval(-daysAgo * 24 * 3600)
        return Walk(startedAt: start, endedAt: start.addingTimeInterval(1800), distance: metres, newTiles: tiles)
    }

    func place(left: Int) -> WalkRecap.Place {
        WalkRecap.Place(id: UUID(), name: "Geographe", before: 0.1, after: 0.12, newTiles: 10, tilesLeft: left)
    }

    @Test func predictsWalksFromYourAverage() {
        let history = [walk(daysAgo: 6, tiles: 20), walk(daysAgo: 3, tiles: 10)]
        let prediction = WalkRecap.prediction(for: place(left: 300), walk: walk(daysAgo: 0, tiles: 30), history: history, now: now)
        // Averaging 20 a walk, 300 left.
        #expect(prediction?.walks == 15)
        #expect(prediction?.walksPerWeek == 3)
        #expect(prediction?.weeks == 5)
    }

    @Test func shortPottersDontDragTheAverageDown() {
        let history = [walk(daysAgo: 2, tiles: 0, metres: 40), walk(daysAgo: 1, tiles: 1, metres: 120)]
        let prediction = WalkRecap.prediction(for: place(left: 100), walk: walk(daysAgo: 0, tiles: 25), history: history, now: now)
        #expect(prediction?.walks == 4)
    }

    @Test func noPredictionWhenThereIsNothingToGoOn() {
        #expect(WalkRecap.prediction(for: place(left: 100), walk: walk(daysAgo: 0, tiles: 0), history: [], now: now) == nil)
        #expect(WalkRecap.prediction(for: place(left: 0), walk: walk(daysAgo: 0, tiles: 9), history: [], now: now) == nil)
        #expect(WalkRecap.prediction(for: nil, walk: walk(daysAgo: 0, tiles: 9), history: [], now: now) == nil)
    }

    @Test func oneWalkGivesACountButNoPace() {
        let prediction = WalkRecap.prediction(for: place(left: 50), walk: walk(daysAgo: 0, tiles: 10), history: [], now: now)
        #expect(prediction?.walks == 5)
        #expect(prediction?.walksPerWeek == nil)
    }

    func recap(times: [Double], duration: Double = 1800) -> WalkRecap {
        let start = now
        let walk = Walk(startedAt: start, endedAt: start.addingTimeInterval(duration))
        return WalkRecap(walk: walk, route: times.map { _ in Coordinate(lat: 0, lon: 0) }, routeTimes: times,
                         reveals: [], secrets: [], places: [], prediction: nil, isBest: false, before: [], after: [])
    }

    @Test func elapsedFollowsTheWalksOwnClock() {
        // Five points along the route, with a ten-minute stop between the third and fourth.
        let recap = recap(times: [0, 60, 120, 720, 780], duration: 800)
        #expect(recap.elapsed(at: 0) == 0)
        #expect(recap.elapsed(at: 0.25) == 60)
        #expect(recap.elapsed(at: 0.5) == 120)
        // Halfway between the third and fourth points is halfway through the stop.
        #expect(recap.elapsed(at: 0.625) == 420)
        #expect(recap.elapsed(at: 0.75) == 720)
    }

    @Test func elapsedEndsOnTheWalksFullTime() {
        let recap = recap(times: [5, 60, 120], duration: 150)
        #expect(recap.elapsed(at: 1) == 150)
        #expect(recap.elapsed(at: 1) == recap.walk.duration)
        #expect(recap.elapsed(at: 0.999) <= 150)
    }

    @Test func elapsedWithoutTimesSpreadsTheWalkEvenly() {
        let recap = recap(times: [], duration: 600)
        #expect(recap.elapsed(at: 0.5) == 300)
        #expect(recap.elapsed(at: 1) == 600)
    }

    @Test func routeSamplesCarryTheirFixesTimes() {
        let origin = Coordinate(lat: -33.65, lon: 115.35)
        let points = (0..<3).map { i in
            TrackPoint(lat: origin.lat + Double(i) * 0.0002, lon: origin.lon, time: 1000 + Double(i) * 20, accuracy: 5, speed: 1.2)
        }
        let (samples, times) = CoverageTracer.timedSamples(for: points)
        #expect(samples.count == times.count)
        #expect(samples == CoverageTracer.samples(for: points))
        #expect(times == times.sorted())
        #expect(times.first.map { $0 > 1000 && $0 <= 1020 } == true)
        #expect(times.last == 1040)
    }

    @Test func rewatchIsOffByDefault() {
        #expect(!recap(times: []).isRewatch)
    }
}
