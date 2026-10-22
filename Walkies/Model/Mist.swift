import Foundation

/// When each tile was last walked, for the mist. Saved with the place as
/// `[[q, r, minute], ...]`, the minute in whole minutes since 1970 (UTC), the same on
/// both phones (`City.lastWalked` in City.kt).
nonisolated struct LastWalked: Codable, Equatable, Sendable {
    var minutes: [Hex: Int]

    init(_ minutes: [Hex: Int] = [:]) {
        self.minutes = minutes
    }

    subscript(hex: Hex) -> Int? { minutes[hex] }
    var isEmpty: Bool { minutes.isEmpty }

    /// Keeps whichever is later.
    mutating func record(_ hex: Hex, minute: Int) {
        if let old = minutes[hex], old >= minute { return }
        minutes[hex] = minute
    }

    mutating func merge(_ other: LastWalked) {
        for (hex, minute) in other.minutes { record(hex, minute: minute) }
    }

    /// Any tile walked later here than in `other`, or not there at all.
    func hasLater(than other: LastWalked?) -> Bool {
        minutes.contains { hex, minute in (other?.minutes[hex]).map { minute > $0 } ?? true }
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var minutes: [Hex: Int] = [:]
        while !c.isAtEnd {
            var entry = try c.nestedUnkeyedContainer()
            let hex = Hex(q: try entry.decode(Int32.self), r: try entry.decode(Int32.self))
            minutes[hex] = max(minutes[hex] ?? .min, try entry.decode(Int.self))
        }
        self.minutes = minutes
    }

    /// In tile order, so the same record always writes the same file.
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for (hex, minute) in minutes.sorted(by: { ($0.key.q, $0.key.r) < ($1.key.q, $1.key.r) }) {
            var entry = c.nestedUnkeyedContainer()
            try entry.encode(hex.q)
            try entry.encode(hex.r)
            try entry.encode(minute)
        }
    }
}

/// Tiles you walked but haven't walked again for a while go misty: a pale haze over
/// them, nothing more. Your %, tiles, shells, XP, quests and secrets never change
/// because of it. Walking through a misty tile clears it again.
nonisolated enum Mist {
    static let defaultDays = 60.0

    /// How long until a walked tile mists over. `-mistDays <number>` overrides it
    /// (0.001 is about a minute and a half), to see it without waiting two months.
    static var days: Double {
        let override = UserDefaults.standard.double(forKey: "mistDays")
        return override > 0 ? override : defaultDays
    }

    /// A tile walked within this many seconds isn't noted again as you walk round it,
    /// so a walk doesn't change the place every few steps. Misty tiles always are.
    static let refresh = 3600.0

    /// Whole minutes since 1970, from seconds since 1970.
    static func minute(_ seconds: Double) -> Int {
        Int((seconds / 60).rounded(.down))
    }

    static func isMisty(minute: Int, now: Double, days: Double) -> Bool {
        now - Double(minute) * 60 > days * 86_400
    }

    /// The misty tiles across all these places at `now`: walked, and not walked again
    /// for `days`. A tile in two places goes by whichever saw you last. Tiles with no
    /// walk on record (cleared for free beside one, or from before anything was kept)
    /// never mist.
    static func tiles(in cities: [City], now: Date, days: Double) -> Set<Hex> {
        var latest: [Hex: Int] = [:]
        for city in cities {
            guard let walked = city.lastWalked else { continue }
            for (hex, minute) in walked.minutes where city.visited.contains(hex) {
                latest[hex] = max(latest[hex] ?? minute, minute)
            }
        }
        let seconds = now.timeIntervalSince1970
        return Set(latest.filter { isMisty(minute: $0.value, now: seconds, days: days) }.keys)
    }

    /// Changes as often as tiles could newly mist over while the app's open, for the
    /// clouds to look again: hourly, or more often with a short `-mistDays`.
    static func epoch(_ now: Date, days: Double) -> Int {
        let step = min(3600, max(30, days * 86_400 / 4))
        return Int(now.timeIntervalSince1970 / step)
    }
}

nonisolated extension City {
    /// Notes the tiles under these points as walked at `time` (seconds since 1970), for
    /// the mist. Call it after `visit`, so only tiles that count are noted. Returns
    /// whether anything changed, and the misty tiles it cleared.
    @discardableResult
    mutating func noteWalked(_ points: [Coordinate], at time: Double, mistDays: Double) -> (changed: Bool, cleared: Set<Hex>) {
        let minute = Mist.minute(time)
        var walked = lastWalked ?? LastWalked()
        var changed = false
        var cleared = Set<Hex>()
        var seen = Set<Hex>()
        for point in points {
            let hex = grid.hex(containing: point)
            guard seen.insert(hex).inserted, visited.contains(hex) else { continue }
            if let old = walked[hex] {
                if Mist.isMisty(minute: old, now: time, days: mistDays) {
                    cleared.insert(hex)
                } else if time - Double(old) * 60 < Mist.refresh || old >= minute {
                    continue
                }
            }
            walked.record(hex, minute: minute)
            changed = true
        }
        if changed { lastWalked = walked }
        return (changed, cleared)
    }

    /// Keeps the later date for every tile.
    mutating func mergeLastWalked(_ other: LastWalked?) {
        guard let other else { return }
        var walked = lastWalked ?? LastWalked()
        walked.merge(other)
        lastWalked = walked
    }

    /// When each place's tiles were last walked, worked out from the saved walks'
    /// routes (the time each spot was passed) and the dated tile credits. Only tiles
    /// in `visited` are noted: the ones cleared for free beside a walk never mist.
    /// Traces each walk once for all the places. Slow for a long history: off the main thread.
    static func lastWalked(for cities: [City], from walks: [Walk]) -> [UUID: LastWalked] {
        var out = Dictionary(uniqueKeysWithValues: cities.map { ($0.id, LastWalked()) })
        for city in cities {
            for credit in city.tileCredits ?? [] {
                let minute = Mist.minute(credit.at.timeIntervalSince1970)
                for hex in credit.hexes where city.visited.contains(hex) { out[city.id]?.record(hex, minute: minute) }
            }
        }
        let grid = HexGrid.world
        for walk in walks {
            let timed = CoverageTracer.timedSamples(for: walk.points)
            var latest: [Hex: Int] = [:]
            for (sample, time) in zip(timed.samples, timed.times) {
                let hex = grid.hex(containing: sample)
                latest[hex] = max(latest[hex] ?? .min, Mist.minute(time))
            }
            for city in cities {
                for (hex, minute) in latest where city.visited.contains(hex) { out[city.id]?.record(hex, minute: minute) }
            }
        }
        return out
    }
}
