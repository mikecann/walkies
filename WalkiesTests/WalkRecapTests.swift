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
}
