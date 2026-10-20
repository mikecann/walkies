import Foundation
import Testing
@testable import Walkies

struct ProgressionTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Perth")!
        return c
    }
    var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))! }
    var origin: Coordinate { Coordinate(lat: -33.638, lon: 115.386) }

    func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: monday)! }

    func city(visited: Int, total: Int = 100, id: UUID = UUID()) -> City {
        let grid = HexGrid(projection: LocalProjection(origin: origin), size: 50)
        let ring = [SIMD2(-1000.0, -1000), SIMD2(1000.0, -1000), SIMD2(1000.0, 1000), SIMD2(-1000.0, 1000)].map(grid.projection.unproject)
        return City(id: id, name: "Geographe", detail: "Busselton", grid: grid,
                    boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]),
                    tiles: Set((0..<total).map { Hex(q: Int32($0), r: 0) }),
                    visited: Set((0..<visited).map { Hex(q: Int32($0), r: 0) }))
    }

    func walk(_ n: Int = 0, tiles: Int = 0, metres: Double = 300, place: UUID? = nil) -> Walk {
        var walk = Walk(startedAt: day(n), endedAt: day(n).addingTimeInterval(1800), distance: metres, newTiles: tiles)
        walk.newTilesByPlace = [(place ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!).uuidString: tiles]
        return walk
    }

    func inputs(cities: [City] = [], walks: [Walk] = [], secrets: [String: Date] = [:], now: Date? = nil) -> Progression.Inputs {
        Progression.Inputs(cities: cities, walks: walks, foundSecrets: secrets, now: now ?? day(6), calendar: calendar)
    }

    @Test func catalogMatchesPricesAndDefaults() {
        #expect(Progression.catalog.count == 21)
        #expect(Progression.catalog.filter(\.isFree).count == 5)
        #expect(Progression.item("spyglass")?.price == 60)
        #expect(Progression.item("trail.sparkles")?.price == 250)
        #expect(Ledger().owned.count == 5)
    }

    @Test func mergeUnionsAndKeepsFirstClaimAndLaterEquipment() throws {
        var first = Ledger()
        first.purchases = [.init(id: "a", item: "spyglass", cost: 60, at: 10)]
        first.claims = [.init(level: 2, choice: Progression.shellBag)]
        first.spyglasses = [.init(id: "s1", secretId: "secret", centre: [0, 1], at: 12)]
        first.preparePicks(xp: 150)
        var second = Ledger()
        second.purchases = [.init(id: "a", item: "spyglass", cost: 99, at: 10), .init(id: "b", item: "trail.sparkles", cost: 250, at: 20)]
        second.claims = [.init(level: 2, choice: Progression.spyglassPair), .init(level: 4, choice: Progression.spyglassPair)]
        second.spyglasses = [.init(id: "s1", secretId: "different", centre: [2, 3], at: 14), .init(id: "s2", secretId: "other", centre: [1, 2], at: 15)]
        second.equipped.trail = "trail.sparkles"
        second.equipped.updatedAt = 20
        let merged = first.merged(with: second)
        #expect(merged.purchases.count == 2)
        #expect(merged.purchases[0].cost == 60)
        #expect(merged.claims.count == 2)
        #expect(merged.claims[0].choice == Progression.shellBag)
        #expect(merged.spyglasses.count == 2)
        #expect(merged.spyglasses[0].secretId == "secret")
        #expect(merged.equipped.trail == "trail.sparkles")
        #expect(merged.merged(with: second) == merged)
        #expect(try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(merged)) == merged)
    }

    @Test func equipmentClockTiesKeepReceiver() {
        var a = Ledger(), b = Ledger()
        a.equipped.trail = "trail.footprints"
        b.equipped.trail = "trail.sparkles"
        #expect(a.merged(with: b).equipped.trail == "trail.footprints")
    }

    @Test func originalLedgerWithoutOffersStillDecodes() throws {
        let json = """
        {"purchases":[],"claims":[],"spyglasses":[],"equipped":{"marker":"marker.dot","trail":"trail.teal","clouds":"clouds.classic","cover":"cover.red","celebration":"celebration.confetti","updatedAt":1790000000}}
        """
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
        #expect(ledger.offers == nil)
        #expect(ledger.equipped.updatedAt == 1_790_000_000)
    }

    @Test func tilesUseIntersectionAndMilestonesAreCumulative() {
        var a = city(visited: 50)
        a.visited.insert(Hex(q: 999, r: 0)) // Non-counting coverage earns nothing.
        let earned = Progression.state(inputs(cities: [a, city(visited: 100)])).earned
        #expect(earned.tiles == 150)
        #expect(earned.milestones == 100 + 525)
        #expect(Progression.state(inputs(cities: [city(visited: 0, total: 0)])).earned.total == 0)
    }

    @Test func secretsAreTenEachAndFutureFindsDontCountYet() {
        let state = Progression.state(inputs(secrets: ["one": day(0), "two": day(1), "future": day(20)]))
        #expect(state.earned.secrets == 20)
    }

    @Test func streakDeduplicatesDaysCapsAndResets() {
        var walks = (0..<8).map { walk($0) }
        walks += [walk(2), walk(9, metres: 299), walk(10)]
        let state = Progression.state(inputs(walks: walks, now: day(10)))
        #expect(state.earned.streaks == 125) // 0, 5, 10, 15, 20, 25, 25, 25.
    }

    @Test func streakUsesCalendarDaysAcrossDST() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let start = c.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
        let walks = (0..<3).map { n in
            let date = c.date(byAdding: .day, value: n, to: start)!
            return Walk(startedAt: date, endedAt: date.addingTimeInterval(600), distance: 300)
        }
        let state = Progression.state(.init(walks: walks, now: walks.last!.startedAt, calendar: c))
        #expect(state.earned.streaks == 15)
    }

    @Test func levelCurveAndPendingPicks() {
        #expect((1...7).map(Progression.xp(for:)) == [0, 50, 150, 300, 500, 750, 1050])
        for level in 2...100 {
            #expect(Progression.level(for: Progression.xp(for: level)) == level)
            #expect(Progression.level(for: Progression.xp(for: level) - 1) == level - 1)
        }
        var ledger = Ledger()
        ledger.claims = [.init(level: 2, choice: Progression.shellBag)]
        #expect(Progression.pendingLevels(xp: 300, ledger: ledger) == [3, 4])
        #expect(Progression.pendingLevels(xp: 0, ledger: ledger).isEmpty)
    }

    @Test func picksAreSeededPreferUnownedAndFreezeInLedger() {
        let first = Progression.picks(for: 4)
        #expect(first == Progression.picks(for: 4))
        #expect(first.count == 3)
        #expect(Set(first).count == 3)
        let owned = Set([first[0]])
        #expect(!Progression.picks(for: 4, owned: owned).contains(first[0]))
        var ledger = Ledger()
        ledger.preparePicks(xp: 300)
        let frozen = ledger.picks(for: 4)
        ledger.purchases.append(.init(item: frozen[0], cost: 150, at: 0))
        ledger.preparePicks(xp: 300)
        #expect(ledger.picks(for: 4) == frozen)
        var other = Ledger()
        other.offers = [.init(level: 4, choices: ["x", "y", "z"])]
        #expect(ledger.merged(with: other).picks(for: 4) == frozen)
        let allOwned = Set(Progression.catalog.map(\.id))
        #expect(Progression.picks(for: 99, owned: allOwned).contains(Progression.shellBag))
        #expect(Progression.picks(for: 99, owned: allOwned).contains(Progression.spyglassPair))
    }

    @Test func weeksStartMondayEvenForSundayFirstCalendars() {
        var c = calendar
        c.firstWeekday = 1
        let week = Progression.week(containing: day(6), calendar: c)
        #expect(c.component(.weekday, from: week.start) == 2)
        #expect(week.start <= monday && monday < week.end)
        #expect(Progression.week(containing: day(7), calendar: c).start == week.end)
        let january = c.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        #expect(Progression.week(containing: january, calendar: c).year == 2026)
    }

    @Test func weeklyQuestsAreStableAndProgressUsesOnlyTheirWeek() {
        let week = Progression.week(containing: monday, calendar: calendar)
        #expect(Progression.questKinds(for: week) == Progression.questKinds(for: week))
        #expect(Set(Progression.questKinds(for: week)).count == 3)
        let input = inputs(walks: [walk(-1, tiles: 99, metres: 9000), walk(0, tiles: 20, metres: 2000), walk(1, tiles: 15, metres: 2000), walk(2, tiles: 25, metres: 1000), walk(7, tiles: 99, metres: 9000)], secrets: ["a": day(2), "b": day(-1)])
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == 60)
        #expect(Progression.questProgress(.tiles60, week: week, inputs: input) == 60)
        #expect(Progression.questProgress(.secret, week: week, inputs: input) == 1)
        #expect(Progression.questProgress(.days3, week: week, inputs: input) == 3)
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 5000)
        let completed = Progression.quests(for: week, inputs: input).filter(\.isComplete).count
        #expect(completed >= 2)
        #expect(Progression.state(input).earned.quests >= completed * 40)
    }

    @Test func anotherPlaceUsesTheFavouriteAtWeekStart() {
        let a = city(visited: 50), b = city(visited: 10)
        let week = Progression.week(containing: monday, calendar: calendar)
        let prior = walk(-2, tiles: 50, place: a.id)
        let input = inputs(cities: [a, b], walks: [prior, walk(0, tiles: 10, place: b.id)])
        #expect(Progression.questProgress(.anotherPlace, week: week, inputs: input) == 1)
        #expect(Progression.questProgress(.anotherPlace, week: week, inputs: inputs(cities: [a, b], walks: [prior, walk(0, tiles: 10, place: a.id)])) == 0)
    }

    @Test func priorQuestRewardsDontDisappearNextMonday() {
        let input = inputs(walks: [walk(0, tiles: 60, metres: 5000), walk(1), walk(2)], secrets: ["a": day(1)])
        let next = inputs(walks: input.walks, secrets: input.foundSecrets, now: day(7))
        #expect(Progression.state(input).earned.quests == Progression.state(next).earned.quests)
        #expect(Progression.state(next).quests.allSatisfy { $0.progress == 0 })
    }

    @Test func balanceOwnsPurchasesAndKeepsOfflineDebt() {
        var ledger = Ledger()
        ledger.purchases = [.init(item: "trail.sparkles", cost: 250, at: 0)]
        ledger.claims = [.init(level: 2, choice: Progression.shellBag), .init(level: 3, choice: "cover.gold")]
        #expect(ledger.spent == 250)
        #expect(ledger.balance(earned: 300) == 100)
        #expect(ledger.balance(earned: 0) == -200)
        #expect(ledger.owned.contains("trail.sparkles"))
        #expect(ledger.owned.contains("cover.gold"))
        #expect(!ledger.owned.contains("spyglass"))
    }

    @Test func spyglassCountsOnlyConsumablesAndUses() {
        var ledger = Ledger()
        ledger.purchases = [.init(item: "spyglass", cost: 60, at: 0)]
        ledger.claims = [.init(level: 2, choice: Progression.spyglassPair)]
        #expect(ledger.spyglassesLeft == 3)
        ledger.spyglasses = [.init(secretId: "a", centre: [0, 1], at: 1)]
        #expect(ledger.spyglassesLeft == 2)
    }

    @Test func spyglassIsNearestSeededAndExpiresOrEndsWhenFound() throws {
        var place = city(visited: 0)
        place.stickers = ["near": Hex(q: 0, r: 0), "far": Hex(q: 10, r: 0)]
        let use = try #require(Progression.spyglass(in: place, from: origin, found: [:], now: monday, id: "one"))
        let again = try #require(Progression.spyglass(in: place, from: origin, found: [:], now: day(1), id: "two"))
        #expect(use.secretId == "near")
        #expect(use.centre == again.centre)
        #expect(Coordinate(lat: use.centre[0], lon: use.centre[1]).distance(to: origin) <= 120.1)
        var ledger = Ledger()
        ledger.spyglasses = [use]
        let ring = try #require(Progression.activeRing(in: place, ledger: ledger, found: [:], now: monday))
        #expect(ring.radius == 125)
        #expect(Progression.activeRing(in: place, ledger: ledger, found: [:], now: monday.addingTimeInterval(10800)) == nil)
        #expect(Progression.activeRing(in: place, ledger: ledger, found: ["near": monday], now: monday) == nil)
        #expect(Progression.spyglass(in: place, from: nil, found: ["near": monday, "far": monday], now: monday) == nil)
        let other = city(visited: 0)
        #expect(Progression.activeRing(in: other, ledger: ledger, found: [:], now: monday) == nil)
    }

    @Test func oneWalkReportsShellsXPAndQuestGains() {
        var place = city(visited: 9)
        let before = inputs(cities: [place], walks: [walk(-1)], now: day(0))
        place.visited.insert(Hex(q: 9, r: 0))
        let after = inputs(cities: [place], walks: before.walks + [walk(0, tiles: 1)], secrets: ["new": day(0)], now: day(0))
        let earned = Progression.walkEarnings(before: before, after: after)
        #expect(earned.breakdown.tiles == 1)
        #expect(earned.breakdown.milestones == 20)
        #expect(earned.breakdown.secrets == 10)
        #expect(earned.breakdown.streaks == 5)
        #expect(earned.shells == earned.breakdown.total)
        #expect(earned.xp == earned.shells)
        #expect(!earned.quests.isEmpty)
        #expect(earned.quests.allSatisfy { $0.gained > 0 })
    }

    @Test func questRewardsAreExactlyFortyPerCompletedQuest() {
        let input = inputs(walks: [walk(0, tiles: 60, metres: 5000), walk(1), walk(2)], secrets: ["a": day(1)])
        let week = Progression.week(containing: monday, calendar: calendar)
        let completed = Progression.quests(for: week, inputs: input).filter(\.isComplete).count
        #expect(Progression.state(input).earned.quests == completed * 40)
    }

    @Test func recapCarriesTheComputedWalkRewards() {
        let place = city(visited: 10)
        let walk = walk(0, tiles: 1)
        let recap = WalkRecap.make(walk: walk, cities: [place], fresh: [place.id: [Hex(q: 9, r: 0)]],
                                   found: ["new": day(0).addingTimeInterval(60)], history: [self.walk(-1)], now: day(0).addingTimeInterval(3600))
        #expect(recap.earnings.breakdown.tiles == 1)
        #expect(recap.earnings.breakdown.milestones == 20)
        #expect(recap.earnings.breakdown.secrets == 10)
        #expect(recap.earnings.breakdown.streaks == 5)
        #expect(recap.shells == recap.earnings.breakdown.total)
        #expect(recap.xp == recap.shells)
    }

    @Test func anotherPlaceUsesStoredCoverageWhenOldWalksAreMissing() {
        let a = city(visited: 50), b = city(visited: 10)
        let week = Progression.week(containing: monday, calendar: calendar)
        let input = inputs(cities: [a, b], walks: [walk(0, tiles: 10, place: b.id)])
        #expect(Progression.questProgress(.anotherPlace, week: week, inputs: input) == 1)
    }


    @Test func legacyRoutesRecoverOnlyNewTilesAndCanBeCached() {
        let place = city(visited: 2)
        func points(_ east: [Double], start: Date) -> [TrackPoint] {
            east.enumerated().map { index, metres in
                let p = place.grid.projection.unproject(SIMD2(metres, 0))
                return TrackPoint(lat: p.lat, lon: p.lon, time: start.timeIntervalSince1970 + Double(index) * 20,
                                  accuracy: 5, speed: 1)
            }
        }
        var first = walk(-1, tiles: 1), second = walk(0, tiles: 1)
        first.newTilesByPlace = nil
        second.newTilesByPlace = nil
        first.points = points([0, 15], start: first.startedAt)
        second.points = points([0, 15, 30, 45, 60, 75, 90], start: second.startedAt)
        var input = inputs(cities: [place], walks: [first, second])
        let counts = Progression.placeTileCounts(input)
        #expect(counts[first.id]?[place.id] == 1)
        #expect(counts[second.id]?[place.id] == 1)
        let original = Progression.state(input)
        input.newTilesByWalk = counts
        #expect(Progression.state(input).earned == original.earned)
        #expect(Progression.state(input).quests == original.quests)
    }

    @Test func duplicatePhoneCoverageCountsEachTileOnlyInItsFirstWeek() throws {
        let place = city(visited: 40)
        let hexes = Set((0..<40).map { Hex(q: Int32($0), r: 0) })
        var first = walk(0, tiles: 40, metres: 3000, place: place.id)
        first.newTileHexesByPlace = [place.id.uuidString: hexes]
        var duplicate = first
        duplicate.id = UUID()
        duplicate.startedAt = first.startedAt.addingTimeInterval(30)
        duplicate.endedAt = first.endedAt?.addingTimeInterval(30)
        let week = Progression.week(containing: monday, calendar: calendar)
        var input = inputs(cities: [place], walks: [duplicate, first])
        #expect(Progression.questProgress(.tiles60, week: week, inputs: input) == 40)
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 3000)
        #expect(Progression.state(input).earned == Progression.state(inputs(cities: [place], walks: [first])).earned)
        let recovered = Progression.backfill(walks: input.walks, cities: input.cities)
        #expect(recovered.walks.allSatisfy { $0.newTilesByPlace?[place.id.uuidString] == 40 })
        let saved = try JSONDecoder().decode([Walk].self, from: JSONEncoder().encode(recovered.walks))
        input.walks = saved
        input.newTilesByWalk = Progression.backfill(walks: saved, cities: [place]).counts
        #expect(Progression.questProgress(.tiles60, week: week, inputs: input) == 40)
        // A repeat in a later week cannot earn the same first-discovery credit.
        duplicate.startedAt = day(7)
        duplicate.endedAt = day(7).addingTimeInterval(1800)
        input = inputs(cities: [place], walks: [first, duplicate], now: day(8))
        let nextWeek = Progression.week(containing: day(7), calendar: calendar)
        #expect(Progression.questProgress(.tiles25, week: nextWeek, inputs: input) == 0)
    }

    @Test func countOnlyHistoryRecoversTileIdentitiesOnceForSyncDeduplication() throws {
        let place = city(visited: 2)
        var first = walk(0, tiles: 2, place: place.id)
        first.points = [0.0, 90.0].enumerated().map { index, x in
            let c = place.grid.projection.unproject(SIMD2(x, 0))
            return TrackPoint(lat: c.lat, lon: c.lon, time: first.startedAt.timeIntervalSince1970 + Double(index) * 40,
                              accuracy: 5, speed: 1)
        }
        var duplicate = first
        duplicate.id = UUID()
        duplicate.startedAt = first.startedAt.addingTimeInterval(1)
        var replays: [UUID] = []
        let backfill = Progression.backfill(walks: [duplicate, first], cities: [place]) { replays.append($0) }
        #expect(Set(replays) == Set([first.id, duplicate.id]))
        #expect(backfill.counts.values.reduce(0) { $0 + $1.values.reduce(0, +) } == 2)
        #expect(backfill.walks.allSatisfy { $0.newTilesByPlace?[place.id.uuidString] == 2 })
        let saved = try JSONDecoder().decode([Walk].self, from: JSONEncoder().encode(backfill.walks))
        replays = []
        #expect(Progression.backfill(walks: saved, cities: [place]) { replays.append($0) }.counts == backfill.counts)
        #expect(replays.isEmpty)
    }

    @Test func distanceOverlapUsesLongerOutingAndStrictHalfOfShorterRange() {
        let first = walk(0, metres: 3000)
        var duplicate = first
        duplicate.id = UUID()
        duplicate.startedAt = first.startedAt.addingTimeInterval(600)
        duplicate.endedAt = first.endedAt?.addingTimeInterval(600)
        duplicate.distance = 3200
        var separate = first
        separate.id = UUID()
        separate.startedAt = first.startedAt.addingTimeInterval(3600)
        separate.endedAt = first.endedAt?.addingTimeInterval(3600)
        separate.distance = 2000
        let week = Progression.week(containing: monday, calendar: calendar)
        let input = inputs(walks: [first, duplicate, separate])
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 5200)
        #expect(Progression.distinctOutings([separate, duplicate, first]).map(\.id) == Progression.distinctOutings(input.walks).map(\.id))
        duplicate.startedAt = first.startedAt.addingTimeInterval(900)
        duplicate.endedAt = first.endedAt?.addingTimeInterval(900)
        #expect(Progression.distinctOutings([first, duplicate]).count == 2)
        // A short recording wholly inside a longer outing is also a duplicate.
        duplicate.startedAt = first.startedAt.addingTimeInterval(100)
        duplicate.endedAt = first.startedAt.addingTimeInterval(200)
        #expect(Progression.distinctOutings([first, duplicate]).count == 1)
    }

    @Test func overlappingDeviceRecordingsMergeTransitivelyAndAcrossWeeks() {
        let monday = Progression.week(containing: self.monday, calendar: calendar).start
        let start = monday.addingTimeInterval(-600)
        let first = Walk(startedAt: start, endedAt: start.addingTimeInterval(1800), distance: 3000)
        let bridge = Walk(startedAt: start.addingTimeInterval(600), endedAt: start.addingTimeInterval(2400), distance: 2900)
        let third = Walk(startedAt: start.addingTimeInterval(1200), endedAt: start.addingTimeInterval(3000), distance: 2800)
        #expect(Progression.distinctOutings([third, bridge, first]).map(\.id) == [first.id])
        let input = inputs(walks: [third, first, bridge])
        let week = Progression.week(containing: monday, calendar: calendar)
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 0)
        let previous = Progression.week(containing: start, calendar: calendar)
        #expect(Progression.questProgress(.metres5000, week: previous, inputs: input) == 3000)
    }

    @Test func discardedCoverageKeepsWeekStartFavouriteAndWeeklyTileCredit() throws {
        let favourite = city(visited: 100, total: 200)
        var other = city(visited: 110, total: 200)
        let hexes = Set((90..<110).map { Hex(q: Int32($0), r: 0) })
        other.tileCredits = [.init(id: UUID(), at: day(0), hexes: hexes)]
        let week = Progression.week(containing: monday, calendar: calendar)
        var input = inputs(cities: [favourite, other])
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == 20)
        #expect(Progression.questProgress(.anotherPlace, week: week, inputs: input) == 1)
        #expect(Progression.questProgress(.days3, week: week, inputs: input) == 0)
        #expect(Progression.questProgress(.metres5000, week: week, inputs: input) == 0)
        #expect(Progression.state(input).earned.streaks == 0)
        var inFavourite = walk(0, tiles: 1, place: favourite.id)
        inFavourite.newTileHexesByPlace = [favourite.id.uuidString: [Hex(q: 99, r: 0)]]
        input.walks = [inFavourite]
        #expect(Progression.questProgress(.anotherPlace, week: week, inputs: input) == 1)
        // Both phones finding the discarded coverage doesn't duplicate the credit.
        var duplicate = walk(1, tiles: 20, place: other.id)
        duplicate.newTileHexesByPlace = [other.id.uuidString: hexes]
        input.walks.append(duplicate)
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == 21)
        input.cities = try JSONDecoder().decode([City].self, from: JSONEncoder().encode(input.cities))
        #expect(Progression.questProgress(.tiles25, week: week, inputs: input) == 21)
        let before = Progression.state(input).earned.quests
        input.now = day(7)
        #expect(Progression.state(input).earned.quests == before)
    }

    @Test func lastFixSecretAppearsInAutomaticRecapRewardsAndQuestTick() throws {
        // Pick a week containing the secret quest so this pins the tick as well.
        let start = try #require((0..<52).map { day($0 * 7) }.first {
            Progression.questKinds(for: Progression.week(containing: $0, calendar: calendar)).contains(.secret)
        })
        var place = city(visited: 1)
        let entry = try #require(LoreLibrary.all.first)
        let hex = Hex(q: 0, r: 0)
        place.stickers = [entry.id: hex]
        let end = start.addingTimeInterval(600)
        let walk = Walk(startedAt: start, endedAt: end, distance: 300, newTiles: 1,
                        newTilesByPlace: [place.id.uuidString: 1], newTileHexesByPlace: [place.id.uuidString: [hex]], automatic: true)
        let recap = WalkRecap.make(walk: walk, cities: [place], fresh: [place.id: [hex]],
                                   found: [entry.id: end.addingTimeInterval(0.1)], history: [], now: end.addingTimeInterval(1), counts: [:])
        #expect(recap.secrets.map { $0.entry.id } == [entry.id])
        #expect(recap.earnings.breakdown.secrets == 10)
        #expect(recap.earnings.breakdown.quests == 40)
        #expect(recap.questProgress.contains { $0.kind == .secret && $0.completed })
        #expect(recap.xp == recap.earnings.breakdown.total)
    }

    @Test func equipmentFromALosingOfflineClaimFallsBackWithoutChangingLedger() {
        var ledger = Ledger()
        ledger.equipped.trail = "trail.sparkles"
        ledger.equipped.updatedAt = 20
        #expect(ledger.resolvedEquipment.trail == "trail.teal")
        #expect(ledger.equipped.trail == "trail.sparkles")
        ledger.claims.append(.init(level: 2, choice: "trail.sparkles"))
        #expect(ledger.resolvedEquipment.trail == "trail.sparkles")
        #expect(ledger.resolvedEquipment.updatedAt == 20)
    }

    @Test func mixedSavedAndLegacyWalksKeepCountsAndOnlyRecoverTheRequiredPrefix() throws {
        let place = city(visited: 2)
        var saved = walk(-2, tiles: 1, place: place.id)
        saved.newTileHexesByPlace = [place.id.uuidString: [Hex(q: 0, r: 0)]]
        var legacy = walk(-1, tiles: 1)
        legacy.newTilesByPlace = nil
        legacy.points = [0.0, 90.0].enumerated().map { index, x in
            let p = place.grid.projection.unproject(SIMD2(x, 0))
            return TrackPoint(lat: p.lat, lon: p.lon, time: legacy.startedAt.timeIntervalSince1970 + Double(index) * 40,
                              accuracy: 5, speed: 1)
        }
        let tail = walk(0, tiles: 99, place: place.id)
        var replays: [UUID] = []
        let recovered = Progression.backfill(walks: [tail, legacy, saved], cities: [place]) { replays.append($0) }
        #expect(replays == [legacy.id])
        #expect(recovered.counts[saved.id]?[place.id] == 1)
        #expect(recovered.counts[legacy.id]?[place.id] == 1)
        #expect(recovered.counts[tail.id]?[place.id] == 99)
        let persisted = try JSONDecoder().decode([Walk].self, from: JSONEncoder().encode(recovered.walks))
        replays = []
        #expect(Progression.backfill(walks: persisted, cities: [place]) { replays.append($0) }.counts == recovered.counts)
        #expect(replays.isEmpty)
    }

    @Test func mixedOldCountOnlyPrefixIsRecoveredOnceWithoutOverwritingSavedCounts() {
        let place = city(visited: 2)
        var saved = walk(-1, tiles: 1, place: place.id), legacy = walk(0, tiles: 1)
        func points(start: Date, end: Double) -> [TrackPoint] {
            [0.0, end].enumerated().map { index, x in
                let p = place.grid.projection.unproject(SIMD2(x, 0))
                return TrackPoint(lat: p.lat, lon: p.lon, time: start.timeIntervalSince1970 + Double(index) * 40,
                                  accuracy: 5, speed: 1)
            }
        }
        saved.points = points(start: saved.startedAt, end: 15)
        legacy.newTilesByPlace = nil
        legacy.points = points(start: legacy.startedAt, end: 90)
        var replays: [UUID] = []
        let recovered = Progression.backfill(walks: [saved, legacy], cities: [place]) { replays.append($0) }
        #expect(replays == [saved.id, legacy.id])
        #expect(recovered.counts[saved.id]?[place.id] == 1)
        #expect(recovered.counts[legacy.id]?[place.id] == 1)
        replays = []
        _ = Progression.backfill(walks: recovered.walks, cities: [place]) { replays.append($0) }
        #expect(replays.isEmpty)
    }

    @Test func recapDoesNotReawardMilestoneWhenWalkAddsACountingTile() {
        var place = city(visited: 10)
        let fresh = Hex(q: -1, r: 0)
        place.tiles.insert(fresh)
        place.visited.insert(fresh)
        var walk = walk(0, tiles: 1, place: place.id)
        walk.addedTilesByPlace = [place.id.uuidString: [fresh]]
        let recap = WalkRecap.make(walk: walk, cities: [place], fresh: [place.id: [fresh]], found: [:], history: [], counts: [:])
        #expect(recap.earnings.breakdown.milestones == 0)
        #expect(recap.earnings.breakdown.tiles == 1)
        #expect(recap.shells == 1)
        #expect(recap.places.first?.before == 0.1)
        #expect(recap.before.first?.tiles.count == 100)
    }

    @Test func exploredSecretsAreFoundWithoutRewardingShellsOrQuests() throws {
        let found = ["explored": Progression.exploredSecretDate, "walked": day(0)]
        let roundTrip = try JSONDecoder().decode([String: Date].self, from: JSONEncoder().encode(found))
        #expect(roundTrip["explored"] == Progression.exploredSecretDate)
        let input = inputs(secrets: roundTrip)
        #expect(Progression.state(input).earned.secrets == 10)
        #expect(Progression.questProgress(.secret, week: Progression.week(containing: monday, calendar: calendar), inputs: input) == 1)
    }

    @Test func historicalRewardsCanBeReusedWhileLiveTileAndCurrentQuestProgressChanges() {
        let favourite = city(visited: 50), other = city(visited: 10)
        var input = inputs(cities: [favourite, other], walks: [walk(-14, tiles: 60, metres: 5000, place: other.id)])
        input.newTilesByWalk = Progression.placeTileCounts(input)
        let history = Progression.historicalRewards(input)
        let before = Progression.state(input)
        input.historicalRewards = history
        input.cities[1].visited.insert(Hex(q: 10, r: 0))
        input.unrecordedTilesByPlace = [other.id: 1]
        let after = Progression.state(input)
        #expect(after.earned.tiles == before.earned.tiles + 1)
        #expect(after.earned.quests == before.earned.quests)
        #expect(after.earned.streaks == before.earned.streaks)
        #expect(history.questsByWeek == Progression.historicalRewards(input).questsByWeek)
    }

    @Test func progressionHomeCalendarKeepsSundayWalksAndLifetimeXPStableWhenTravelling() {
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 30))!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(Progression.week(containing: sunday, calendar: tokyo) != Progression.week(containing: sunday, calendar: Progression.calendar))
        let walk = Walk(startedAt: sunday, endedAt: sunday.addingTimeInterval(600), distance: 5000, newTiles: 60, newTilesByPlace: [:])
        let input = Progression.Inputs(walks: [walk], foundSecrets: ["secret": sunday], now: sunday.addingTimeInterval(86400))
        #expect(input.calendar.timeZone.identifier == "Australia/Perth")
        let state = Progression.state(input)
        let homeWeek = Progression.week(containing: sunday, calendar: Progression.calendar)
        let completed = Progression.quests(for: homeWeek, inputs: input).filter(\.isComplete).count
        #expect(state.earned.quests == completed * 40)
        // Device calendars never enter the default production inputs.
        #expect(Progression.Inputs().calendar == Progression.calendar)
    }

    @Test func aWeekNeverGetsBothTileQuests() {
        for year in 2026...2030 {
            for number in 1...52 {
                let kinds = Progression.questKinds(for: Progression.Week(start: .distantPast, end: .distantFuture, year: year, number: number))
                #expect(Set(kinds).count == 3)
                #expect(!(kinds.contains(.tiles25) && kinds.contains(.tiles60)))
            }
        }
    }
}
