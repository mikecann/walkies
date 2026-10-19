import Foundation

/// Presentation values for a level bar. XP remains lifetime earnings, even after spending.
nonisolated struct LevelMeter: Equatable {
    let xp: Int
    var level: Int { Progression.level(for: xp) }
    var start: Int { Progression.xp(for: level) }
    var end: Int { Progression.xp(for: level + 1) }
    var fraction: Double { Double(xp - start) / Double(end - start) }

    init(xp: Int) { self.xp = max(0, xp) }

    struct Fill: Equatable {
        let level: Int
        let from: Double
        let to: Double
    }

    /// Fill each crossed level before starting the next bar. An exact threshold
    /// ends on the new level's empty bar, rather than leaving the old one full.
    static func fills(from before: Int, to after: Int) -> [Fill] {
        let first = LevelMeter(xp: before)
        let last = LevelMeter(xp: max(before, after))
        return (first.level...last.level).map { level in
            Fill(level: level, from: level == first.level ? first.fraction : 0,
                 to: level == last.level ? last.fraction : 1)
        }
    }
}
