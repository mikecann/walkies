import Foundation

/// Walking earns shells. The ledger only records choices and spending, never coverage.
nonisolated enum Progression {
    enum Group: String, Codable, CaseIterable, Sendable {
        case marker, trail, clouds, cover, celebration
    }

    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        /// Nil for the consumable spyglass.
        var group: Group?
        var price: Int
        var isFree: Bool { price == 0 }
    }

    static let catalog: [Item] = [
        Item(id: "marker.dot", name: "Classic dot", group: .marker, price: 0),
        Item(id: "marker.sneaker", name: "Sneaker", group: .marker, price: 150),
        Item(id: "marker.boat", name: "Paper boat", group: .marker, price: 200),
        Item(id: "marker.hat", name: "Explorer hat", group: .marker, price: 250),
        Item(id: "marker.lighthouse", name: "Little lighthouse", group: .marker, price: 300),
        Item(id: "trail.teal", name: "Teal line", group: .trail, price: 0),
        Item(id: "trail.footprints", name: "Footprints", group: .trail, price: 150),
        Item(id: "trail.sparkles", name: "Sparkles", group: .trail, price: 250),
        Item(id: "trail.rainbow", name: "Rainbow", group: .trail, price: 400),
        Item(id: "clouds.classic", name: "Classic", group: .clouds, price: 0),
        Item(id: "clouds.sunset", name: "Sunset", group: .clouds, price: 300),
        Item(id: "clouds.storm", name: "Storm", group: .clouds, price: 300),
        Item(id: "clouds.candy", name: "Cotton candy", group: .clouds, price: 400),
        Item(id: "cover.red", name: "Red leather", group: .cover, price: 0),
        Item(id: "cover.seashell", name: "Seashell", group: .cover, price: 200),
        Item(id: "cover.map", name: "Old map", group: .cover, price: 200),
        Item(id: "cover.gold", name: "Gold", group: .cover, price: 500),
        Item(id: "celebration.confetti", name: "Confetti", group: .celebration, price: 0),
        Item(id: "celebration.bubbles", name: "Bubbles", group: .celebration, price: 200),
        Item(id: "celebration.fireworks", name: "Fireworks", group: .celebration, price: 250),
        Item(id: "spyglass", name: "Spyglass", group: nil, price: 60),
    ]

    static func item(_ id: String) -> Item? { catalog.first { $0.id == id } }
    static let shellBag = "shells.50"
    static let spyglassPair = "spyglasses.2"

    struct Inputs: Sendable {
        var cities: [City] = []
        var walks: [Walk] = []
        var foundSecrets: [String: Date] = [:]
        var now: Date = .now
        var calendar: Calendar = Progression.calendar
        /// Optional cached route analysis; independent of visited tiles and spending.
        var newTilesByWalk: [UUID: [UUID: Int]]?
        /// Avoid intersecting every tile set on each GPS fix.
        var countingTilesByPlace: [UUID: Int]?
        /// A live walk isn't in history yet. Its tiles must not move the favourite.
        var unrecordedTilesByPlace: [UUID: Int] = [:]
        var historicalRewards: HistoricalRewards?
    }

    /// History always uses home time, including streak days and the current week.
    /// This keeps lifetime XP stable when the phone travels.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
        return calendar
    }

    /// Found in previously explored coverage, rather than discovered on a walk.
    /// A future sentinel travels through the existing secret wire format. A real
    /// discovery wins the server's earliest-date merge on another phone.
    static let exploredSecretDate = Date.distantFuture

    struct HistoricalRewards: Sendable {
        var streaks: Int
        var questsByWeek: [Week: Int]
    }

    struct Earned: Equatable, Sendable {
        var tiles = 0
        var secrets = 0
        var milestones = 0
        var streaks = 0
        var quests = 0
        var total: Int { tiles + secrets + milestones + streaks + quests }
    }

    enum QuestKind: String, CaseIterable, Codable, Sendable {
        case tiles25, tiles60, secret, days3, metres5000, anotherPlace

        var target: Double {
            switch self {
            case .tiles25: 25
            case .tiles60: 60
            case .secret, .anotherPlace: 1
            case .days3: 3
            case .metres5000: 5000
            }
        }

        var name: String {
            switch self {
            case .tiles25: "Uncover 25 new tiles"
            case .tiles60: "Uncover 60 new tiles"
            case .secret: "Find a secret"
            case .days3: "Walk on 3 different days"
            case .metres5000: "Walk 5 km"
            case .anotherPlace: "Uncover tiles in another place"
            }
        }
    }

    struct Week: Hashable, Sendable {
        var start: Date
        var end: Date
        var year: Int
        var number: Int
    }

    struct Quest: Identifiable, Equatable, Sendable {
        var kind: QuestKind
        var progress: Double
        var id: String { kind.rawValue }
        var name: String { kind.name }
        var target: Double { kind.target }
        var isComplete: Bool { progress >= target }
        var reward: Int { 40 }
    }

    struct QuestGain: Equatable, Sendable {
        var week: Week
        var kind: QuestKind
        var before: Double
        var after: Double
        var target: Double { kind.target }
        var gained: Double { after - before }
        var completed: Bool { before < target && after >= target }
    }

    struct WalkEarnings: Sendable {
        var shells = 0
        var xp = 0
        var breakdown = Earned()
        var quests: [QuestGain] = []
    }

    struct State: Sendable {
        var earned: Earned
        var quests: [Quest]
        var xp: Int { earned.total }
        var level: Int { Progression.level(for: xp) }
        /// Total XP threshold, rather than the amount still to earn.
        var nextLevelXP: Int { Progression.xp(for: level + 1) }
    }

    static func xp(for level: Int) -> Int { 25 * max(0, level) * max(0, level - 1) }

    static func level(for xp: Int) -> Int {
        let estimate = Int((1 + sqrt(1 + Double(max(0, xp)) / 6.25)) / 2)
        return max(1, estimate)
    }

    static func pendingLevels(xp: Int, ledger: Ledger) -> [Int] {
        let level = level(for: xp)
        guard level >= 2 else { return [] }
        let claimed = Set(ledger.claims.map(\.level))
        return (2...level).filter { !claimed.contains($0) }
    }

    /// The seed and ordering are portable, unlike Swift's randomly seeded Hasher.
    /// Ownership is a snapshot: the same level and wardrobe always give the same menu.
    /// The price ceiling grows by 50 per level, starting with 150 at level 2.
    static func picks(for level: Int, owned: Set<String> = []) -> [String] {
        var rng = Seed(UInt64(max(0, level)))
        var pool = catalog.filter { $0.group != nil && !$0.isFree && $0.price <= 50 * max(3, level + 1) && !owned.contains($0.id) }
        var picks: [String] = []
        while !pool.isEmpty && picks.count < 3 {
            picks.append(pool.remove(at: Int(rng.next() % UInt64(pool.count))).id)
        }
        if picks.count < 3 { picks.append(shellBag) }
        if picks.count < 3 { picks.append(spyglassPair) }
        // With an exhausted wardrobe there are only two distinct rewards. A second
        // bag is represented by the same choice id, so either bag is the same claim.
        if picks.count < 3 { picks.append(shellBag) }
        return picks
    }

    static func week(containing date: Date, calendar: Calendar) -> Week {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        return Week(start: interval.start, end: interval.end,
                    year: calendar.component(.yearForWeekOfYear, from: date),
                    number: calendar.component(.weekOfYear, from: date))
    }

    /// Three different quests for the week. The two tile quests are the same quest at
    /// two sizes, so a week never gets both.
    static func questKinds(for week: Week) -> [QuestKind] {
        var rng = Seed(UInt64(week.year) &* 100 &+ UInt64(week.number))
        var pool = QuestKind.allCases
        var picked: [QuestKind] = []
        while picked.count < 3, !pool.isEmpty {
            let kind = pool.remove(at: Int(rng.next() % UInt64(pool.count)))
            picked.append(kind)
            if kind == .tiles25 { pool.removeAll { $0 == .tiles60 } }
            if kind == .tiles60 { pool.removeAll { $0 == .tiles25 } }
        }
        return picked
    }

    /// Finished walks belong to the local week they started in. Secret dates are
    /// independent, so a discovery just after midnight goes in its actual week.
    static func quests(for week: Week, inputs: Inputs) -> [Quest] {
        quests(for: week, inputs: inputs, counts: inputs.newTilesByWalk ?? placeTileCounts(inputs))
    }

    private static func quests(for week: Week, inputs: Inputs, counts: [UUID: [UUID: Int]]) -> [Quest] {
        questKinds(for: week).map { kind in
            Quest(kind: kind, progress: questProgress(kind, week: week, inputs: inputs, counts: counts))
        }
    }

    static func questProgress(_ kind: QuestKind, week: Week, inputs: Inputs) -> Double {
        questProgress(kind, week: week, inputs: inputs, counts: inputs.newTilesByWalk ?? placeTileCounts(inputs))
    }

    private static func questProgress(_ kind: QuestKind, week: Week, inputs: Inputs, counts: [UUID: [UUID: Int]]) -> Double {
        let walks = inputs.walks.filter { $0.endedAt != nil && $0.startedAt >= week.start && $0.startedAt < week.end && $0.startedAt <= inputs.now }
        let coverage = tileRecords(walks: inputs.walks, cities: inputs.cities)
        let weeklyCoverage = coverage.filter { $0.endedAt != nil && $0.startedAt >= week.start && $0.startedAt < week.end && $0.startedAt <= inputs.now }
        switch kind {
        case .tiles25, .tiles60:
            return Double(weeklyCoverage.reduce(0) { total, walk in
                total + (counts[walk.id] ?? [:]).values.reduce(0, +)
            })
        case .secret:
            return Double(inputs.foundSecrets.values.filter { $0 >= week.start && $0 < week.end && $0 <= inputs.now }.count)
        case .days3:
            return Double(Set(walks.map { inputs.calendar.startOfDay(for: $0.startedAt) }).count)
        case .metres5000:
            return weeklyDistance(week: week, walks: inputs.walks, now: inputs.now)
        case .anotherPlace:
            // Freeze the favourite at the start of the week. Otherwise finding tiles
            // elsewhere could change the favourite and undo a completed quest.
            var before = inputs.countingTilesByPlace ?? Dictionary(inputs.cities.map { ($0.id, $0.visited.intersection($0.tiles).count) }, uniquingKeysWith: max)
            for (id, n) in inputs.unrecordedTilesByPlace { before[id, default: 0] -= n }
            for walk in coverage where walk.startedAt >= week.start {
                for (id, n) in counts[walk.id] ?? [:] { before[id, default: 0] -= n }
            }
            let favourite = inputs.cities.sorted {
                let a = max(0, before[$0.id, default: 0]), b = max(0, before[$1.id, default: 0])
                return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
            }.first?.id
            return weeklyCoverage.contains { walk in
                (counts[walk.id] ?? [:]).contains { $0.key != favourite && $0.value > 0 }
            } ? 1 : 0
        }
    }

    /// Deduplicate before filtering the week, including an outing recorded on either
    /// side of midnight on Monday by two phones. Only walks within a day of the week
    /// can overlap one in it, so the rest are left out of the (quadratic) deduplication.
    static func weeklyDistance(week: Week, walks: [Walk], now: Date) -> Double {
        let from = week.start.addingTimeInterval(-24 * 3600), to = week.end.addingTimeInterval(24 * 3600)
        let nearby = walks.filter { walk in
            guard let end = walk.endedAt else { return false }
            return walk.startedAt <= now && end >= from && walk.startedAt < to
        }
        return distinctOutings(nearby)
            .filter { $0.startedAt >= week.start && $0.startedAt < week.end }
            .reduce(0) { $0 + $1.distance }
    }

    /// When two devices record most of the same outing, use the longer distance.
    /// More than half the shorter time range must overlap. Exactly half stays separate.
    static func distinctOutings(_ walks: [Walk]) -> [Walk] {
        let ordered = walks.sorted {
            if $0.distance != $1.distance { return $0.distance > $1.distance }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        func overlaps(_ walk: Walk, _ other: Walk) -> Bool {
            if walk.id == other.id { return true }
            guard let end = walk.endedAt, let otherEnd = other.endedAt else { return false }
            let duration = min(end.timeIntervalSince(walk.startedAt), otherEnd.timeIntervalSince(other.startedAt))
            let overlap = min(end, otherEnd).timeIntervalSince(max(walk.startedAt, other.startedAt))
            return duration > 0 && overlap > duration / 2
        }
        var kept: [Walk] = []
        var grouped: Set<Int> = []
        for index in ordered.indices where !grouped.contains(index) {
            // The first member has the greatest distance. Follow all overlaps so
            // a third phone cannot add the same outing through a shorter bridge.
            kept.append(ordered[index])
            grouped.insert(index)
            var pending = [index]
            while let member = pending.popLast() {
                for candidate in ordered.indices where !grouped.contains(candidate) {
                    guard overlaps(ordered[member], ordered[candidate]) else { continue }
                    grouped.insert(candidate)
                    pending.append(candidate)
                }
            }
        }
        return kept
    }

    /// Tile-only outings share the existing coverage calculation, but never enter
    /// walk history or the distance, day and streak calculations.
    private static func tileRecords(walks: [Walk], cities: [City]) -> [Walk] {
        var credits: [UUID: Walk] = [:]
        let savedIDs = Set(walks.map(\.id))
        for city in cities {
            for credit in city.tileCredits ?? [] where !savedIDs.contains(credit.id) {
                var record = credits[credit.id] ?? Walk(id: credit.id, startedAt: credit.at, endedAt: credit.at,
                                                      newTilesByPlace: [:], newTileHexesByPlace: [:])
                record.newTileHexesByPlace?[city.id.uuidString, default: []].formUnion(credit.hexes)
                record.newTilesByPlace?[city.id.uuidString] = record.newTileHexesByPlace?[city.id.uuidString]?.count
                credits[credit.id] = record
            }
        }
        return walks + credits.values
    }

    static func placeTileCounts(_ inputs: Inputs, onReplay: (UUID) -> Void = { _ in }) -> [UUID: [UUID: Int]] {
        backfill(walks: inputs.walks, cities: inputs.cities, onReplay: onReplay).counts
    }

    struct Backfill: Sendable {
        var walks: [Walk]
        /// Effective first-discovery counts, deduplicated across devices and credits.
        /// The original per-walk records are retained for future merges.
        var counts: [UUID: [UUID: Int]]
    }

    /// Run on a worker at load or after a batch download, then persist recovered
    /// identities. Ordinary state/recap reads use the returned counts without replay.
    static func backfill(walks: [Walk], cities: [City], onReplay: (UUID) -> Void = { _ in }) -> Backfill {
        let ordered = tileRecords(walks: walks, cities: cities).filter { $0.endedAt != nil }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        let savedIDs = Set(walks.map(\.id))
        var seen: [UUID: Set<Hex>] = [:]
        var result: [UUID: [UUID: Int]] = [:]
        var repaired: [Walk] = []
        for original in ordered {
            var walk = original
            if walk.newTileHexesByPlace == nil, walk.newTilesByPlace == nil || !walk.points.isEmpty {
                onReplay(walk.id)
                let samples = CoverageTracer.samples(for: walk.points)
                var freshByPlace: [String: Set<Hex>] = [:]
                for city in cities {
                    let tiles = Set(samples.map(city.grid.hex(containing:))).intersection(city.tiles)
                    freshByPlace[city.id.uuidString] = tiles.subtracting(seen[city.id] ?? [])
                }
                walk.newTileHexesByPlace = freshByPlace
            }
            if walk.newTilesByPlace == nil, let hexes = walk.newTileHexesByPlace {
                walk.newTilesByPlace = hexes.mapValues(\.count)
            }
            if let hexes = walk.newTileHexesByPlace {
                var counts: [UUID: Int] = [:]
                for (key, tiles) in hexes {
                    guard let id = UUID(uuidString: key) else { continue }
                    counts[id] = tiles.subtracting(seen[id] ?? []).count
                    seen[id, default: []].formUnion(tiles)
                }
                result[walk.id] = counts
            } else {
                // Very old count-only records without route data cannot recover
                // identities. Retain their saved credit rather than deleting it.
                result[walk.id] = Dictionary((walk.newTilesByPlace ?? [:]).compactMap { key, n in
                    UUID(uuidString: key).map { ($0, n) }
                }, uniquingKeysWith: +)
            }
            if savedIDs.contains(walk.id) { repaired.append(walk) }
        }
        return Backfill(walks: repaired, counts: result)
    }

    /// Past weeks and streaks are independent of GPS tile revisions. AppModel
    /// retains this until walks, secrets, places or the home day change.
    static func historicalRewards(_ inputs: Inputs) -> HistoricalRewards {
        var inputs = inputs
        if inputs.countingTilesByPlace == nil {
            inputs.countingTilesByPlace = Dictionary(inputs.cities.map { ($0.id, $0.tiles.intersection($0.visited).count) }, uniquingKeysWith: max)
        }
        let walks = inputs.walks.filter { $0.endedAt != nil && $0.startedAt <= inputs.now }
        let days = Set(walks.filter { $0.distance >= 300 }.map { inputs.calendar.startOfDay(for: $0.startedAt) }).sorted()
        var previous: Date?
        var streak = 0
        var streaks = 0
        for day in days {
            streak = previous.flatMap { inputs.calendar.dateComponents([.day], from: $0, to: day).day } == 1 ? streak + 1 : 1
            streaks += min(25, 5 * (streak - 1))
            previous = day
        }
        let current = week(containing: inputs.now, calendar: inputs.calendar)
        let weeks = Set(tileRecords(walks: walks, cities: inputs.cities).filter { $0.startedAt <= inputs.now }.map { week(containing: $0.startedAt, calendar: inputs.calendar) }
            + inputs.foundSecrets.values.filter { $0 <= inputs.now }.map { week(containing: $0, calendar: inputs.calendar) })
        let counts = inputs.newTilesByWalk ?? placeTileCounts(inputs)
        var rewards: [Week: Int] = [:]
        for week in weeks where week != current {
            rewards[week] = quests(for: week, inputs: inputs, counts: counts).filter(\.isComplete).count * 40
        }
        return HistoricalRewards(streaks: streaks, questsByWeek: rewards)
    }

    static func state(_ inputs: Inputs) -> State {
        var inputs = inputs
        if inputs.newTilesByWalk == nil { inputs.newTilesByWalk = placeTileCounts(inputs) }
        if inputs.countingTilesByPlace == nil {
            inputs.countingTilesByPlace = Dictionary(inputs.cities.map { ($0.id, $0.tiles.intersection($0.visited).count) }, uniquingKeysWith: max)
        }
        var earned = Earned()
        let milestones: [(Double, Int)] = [(0.1, 20), (0.25, 30), (0.5, 50), (0.75, 75), (0.9, 100), (1, 250)]
        for city in inputs.cities {
            let count = inputs.countingTilesByPlace?[city.id] ?? 0
            earned.tiles += count
            if !city.tiles.isEmpty {
                let fraction = Double(count) / Double(city.tiles.count)
                earned.milestones += milestones.filter { fraction >= $0.0 }.reduce(0) { $0 + $1.1 }
            }
        }
        earned.secrets = inputs.foundSecrets.values.filter { $0 <= inputs.now }.count * 10
        let history = inputs.historicalRewards ?? historicalRewards(inputs)
        earned.streaks = history.streaks
        let counts = inputs.newTilesByWalk ?? placeTileCounts(inputs)
        let quests = quests(for: week(containing: inputs.now, calendar: inputs.calendar), inputs: inputs, counts: counts)
        earned.quests = history.questsByWeek.values.reduce(0, +) + quests.filter(\.isComplete).count * 40
        return State(earned: earned, quests: quests)
    }

    static func walkEarnings(before: Inputs, after: Inputs) -> WalkEarnings {
        let beforeCounts = before.newTilesByWalk ?? placeTileCounts(before)
        let afterCounts = after.newTilesByWalk ?? placeTileCounts(after)
        var before = before, after = after
        before.newTilesByWalk = beforeCounts
        after.newTilesByWalk = afterCounts
        let old = state(before).earned, new = state(after).earned
        let delta = Earned(tiles: new.tiles - old.tiles, secrets: new.secrets - old.secrets,
                           milestones: new.milestones - old.milestones, streaks: new.streaks - old.streaks,
                           quests: new.quests - old.quests)
        let weeks = Set(after.walks.filter { walk in !before.walks.contains { $0.id == walk.id } }
            .map { week(containing: $0.startedAt, calendar: after.calendar) }
            + [week(containing: after.now, calendar: after.calendar)])
        let gains = weeks.sorted { $0.start < $1.start }.flatMap { week in
            questKinds(for: week).compactMap { kind -> QuestGain? in
                let a = questProgress(kind, week: week, inputs: before, counts: beforeCounts)
                let b = questProgress(kind, week: week, inputs: after, counts: afterCounts)
                return b > a ? QuestGain(week: week, kind: kind, before: a, after: b) : nil
            }
        }
        return WalkEarnings(shells: delta.total, xp: delta.total, breakdown: delta, quests: gains)
    }

    struct Ring: Equatable, Sendable {
        var secretId: String
        var centre: Coordinate
        var radius: Double { 125 }
        var expiresAt: Date
    }

    static func spyglass(in city: City, from location: Coordinate?, found: [String: Date], now: Date, id: String = UUID().uuidString) -> Ledger.Spyglass? {
        let origin = location ?? city.boundary.centre
        let candidates = (city.stickers ?? [:]).filter { found[$0.key] == nil }
        let nearest = candidates.sorted { a, b in
            let da = origin.distance(to: city.grid.projection.unproject(city.grid.centre(of: a.value)))
            let db = origin.distance(to: city.grid.projection.unproject(city.grid.centre(of: b.value)))
            return da == db ? a.key < b.key : da < db
        }.first
        guard let nearest else { return nil }
        var rng = Seed(hash(nearest.key))
        let angle = Double(rng.next() % 1_000_000) / 1_000_000 * 2 * .pi
        let distance = sqrt(Double(rng.next() % 1_000_000) / 1_000_000) * 120
        let centre = city.grid.projection.unproject(city.grid.centre(of: nearest.value) + SIMD2(cos(angle), sin(angle)) * distance)
        return Ledger.Spyglass(id: id, secretId: nearest.key, centre: [centre.lat, centre.lon], at: now.timeIntervalSince1970)
    }

    static func activeRing(in city: City, ledger: Ledger, found: [String: Date], now: Date) -> Ring? {
        ledger.spyglasses.sorted { $0.at == $1.at ? $0.id > $1.id : $0.at > $1.at }.compactMap { use -> Ring? in
            let expiry = Date(timeIntervalSince1970: use.at + 3 * 3600)
            guard city.stickers?[use.secretId] != nil, found[use.secretId] == nil,
                  use.at <= now.timeIntervalSince1970, now < expiry, use.centre.count == 2 else { return nil }
            return Ring(secretId: use.secretId, centre: Coordinate(lat: use.centre[0], lon: use.centre[1]), expiresAt: expiry)
        }.first
    }

    private static func hash(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private struct Seed {
        var value: UInt64
        init(_ seed: UInt64) { value = seed }
        mutating func next() -> UInt64 {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return value
        }
    }
}

/// Times in the ledger are seconds since 1970, in both Swift and TypeScript.
/// Unlike the other save files these dates must not use JSONEncoder's 2001 epoch.
nonisolated struct Ledger: Codable, Equatable, Sendable {
    struct Purchase: Codable, Equatable, Sendable, Identifiable {
        var id = UUID().uuidString
        var item: String
        var cost: Int
        var at: Double
    }

    struct Claim: Codable, Equatable, Sendable {
        var level: Int
        var choice: String
    }

    /// A menu is frozen the first time its level is reached. Keeping it in the
    /// ledger lets us prefer unowned cosmetics without changing an open pick later.
    struct Offer: Codable, Equatable, Sendable {
        var level: Int
        var choices: [String]
    }

    struct Spyglass: Codable, Equatable, Sendable, Identifiable {
        var id = UUID().uuidString
        var secretId: String
        var centre: [Double]
        var at: Double
    }

    struct Equipped: Codable, Equatable, Sendable {
        var marker = "marker.dot"
        var trail = "trail.teal"
        var clouds = "clouds.classic"
        var cover = "cover.red"
        var celebration = "celebration.confetti"
        var updatedAt: Double = 0

        subscript(group: Progression.Group) -> String {
            get {
                switch group {
                case .marker: marker
                case .trail: trail
                case .clouds: clouds
                case .cover: cover
                case .celebration: celebration
                }
            }
            set {
                switch group {
                case .marker: marker = newValue
                case .trail: trail = newValue
                case .clouds: clouds = newValue
                case .cover: cover = newValue
                case .celebration: celebration = newValue
                }
            }
        }
    }

    var purchases: [Purchase] = []
    var claims: [Claim] = []
    var spyglasses: [Spyglass] = []
    var equipped = Equipped()
    /// Optional so the original four-field ledger still decodes. First offer wins.
    var offers: [Offer]?

    /// Receiver wins duplicate ids/levels and equal equipment timestamps. On sync
    /// the server is the receiver, including when accepting its snapshot locally.
    func merged(with other: Ledger) -> Ledger {
        var result = self
        var ids: Set<String> = []
        result.purchases = (purchases + other.purchases).filter { ids.insert($0.id).inserted }
        var levels: Set<Int> = []
        result.claims = (claims + other.claims).filter { levels.insert($0.level).inserted }
        ids = []
        result.spyglasses = (spyglasses + other.spyglasses).filter { ids.insert($0.id).inserted }
        levels = []
        let offers = ((self.offers ?? []) + (other.offers ?? [])).filter { levels.insert($0.level).inserted }
        result.offers = offers.isEmpty ? nil : offers
        if other.equipped.updatedAt > equipped.updatedAt { result.equipped = other.equipped }
        return result
    }

    mutating func preparePicks(xp: Int) {
        for level in Progression.pendingLevels(xp: xp, ledger: self) where !(offers ?? []).contains(where: { $0.level == level }) {
            if offers == nil { offers = [] }
            let choices = Progression.picks(for: level, owned: owned)
            offers?.append(Offer(level: level, choices: choices))
        }
    }

    func picks(for level: Int) -> [String] {
        offers?.first { $0.level == level }?.choices ?? Progression.picks(for: level, owned: owned)
    }

    var spent: Int { purchases.reduce(0) { $0 + $1.cost } }
    /// Reward bags are spending money, not walking XP, so claiming one can't grant
    /// another level by itself. They also never count as tiles or quest progress.
    var rewardShells: Int { claims.filter { $0.choice == Progression.shellBag }.count * 50 }
    func balance(earned: Int) -> Int { earned + rewardShells - spent }
    var owned: Set<String> {
        Set(Progression.catalog.filter(\.isFree).map(\.id))
            .union(purchases.compactMap { Progression.item($0.item)?.group == nil ? nil : $0.item })
            .union(claims.compactMap { Progression.item($0.choice)?.group == nil ? nil : $0.choice })
    }
    /// A losing offline claim can leave its cosmetic equipped but no longer owned.
    /// Keep the raw last-write record for sync; show the free default in that case.
    var resolvedEquipment: Equipped {
        var result = equipped
        let have = owned
        for group in Progression.Group.allCases where !have.contains(result[group]) || Progression.item(result[group])?.group != group {
            result[group] = Progression.catalog.first { $0.group == group && $0.isFree }!.id
        }
        return result
    }

    var spyglassesLeft: Int {
        purchases.filter { $0.item == "spyglass" }.count
            + claims.filter { $0.choice == Progression.spyglassPair }.count * 2 - spyglasses.count
    }
}
