import Testing
@testable import Walkies

struct LevelMeterTests {
    @Test func startsAtLevelOneAndClampsNegativeXP() {
        let meter = LevelMeter(xp: -10)
        #expect(meter.level == 1)
        #expect(meter.start == 0)
        #expect(meter.end == 50)
        #expect(meter.fraction == 0)
    }

    @Test func measuresWithinTheCurrentLevelRatherThanLifetimeXP() {
        let meter = LevelMeter(xp: 100)
        #expect(meter.level == 2)
        #expect(meter.start == 50)
        #expect(meter.end == 150)
        #expect(meter.fraction == 0.5)
    }

    @Test func fillsEveryCrossedLevelAndEndsOnAnEmptyNewLevel() {
        #expect(LevelMeter.fills(from: 25, to: 150) == [
            .init(level: 1, from: 0.5, to: 1),
            .init(level: 2, from: 0, to: 1),
            .init(level: 3, from: 0, to: 0)
        ])
    }

    @Test func partialAndUnchangedWalksHaveOneBar() {
        #expect(LevelMeter.fills(from: 75, to: 100) == [.init(level: 2, from: 0.25, to: 0.5)])
        #expect(LevelMeter.fills(from: 100, to: 100) == [.init(level: 2, from: 0.5, to: 0.5)])
        #expect(LevelMeter.fills(from: 100, to: 20) == [.init(level: 2, from: 0.5, to: 0.5)])
    }

    @Test func startsAtAnExactThresholdAndFinishesPartWayThroughAHigherLevel() {
        let fills = LevelMeter.fills(from: 50, to: 225)
        #expect(fills == [.init(level: 2, from: 0, to: 1), .init(level: 3, from: 0, to: 0.5)])
    }
}
