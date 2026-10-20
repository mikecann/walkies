package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.lore.LoreLibrary
import com.mikecann.walkies.model.Progression.QuestKind
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.map.SplitMix64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID

/**
 * ProgressionTests.swift and LevelMeterTests.swift, case for case, so shells, XP and
 * quests come out the same as on the iPhone for the same data.
 */
class ProgressionTest {
    private val perth: ZoneId = ZoneId.of("Australia/Perth")
    private val monday = date(LocalDateTime.of(2026, 10, 19, 12, 0), perth)
    private val origin = Coordinate(-33.638, 115.386)

    private fun date(local: LocalDateTime, zone: ZoneId) = SwiftDate.epoch(local.atZone(zone).toEpochSecond().toDouble())

    /** Perth has no daylight saving, so a calendar day is always 24 hours. */
    private fun day(n: Int) = monday.plus(n * 86400.0)

    private fun hex(q: Int, r: Int, origin: Coordinate = this.origin): Hex {
        val base = HexGrid.hex(containing = origin)
        return Hex(base.q + q, base.r + r)
    }

    private fun offset(city: City): Vec2 = city.grid.centre(city.grid.hex(containing = city.boundary.centre))

    private fun city(visited: Int, total: Int = 100, id: UUID = UUID.randomUUID()): City {
        val centre = HexGrid.centre(HexGrid.hex(containing = origin))
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(centre + it) }
        return City(
            id = id, name = "Geographe", detail = "Busselton",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until total).mapTo(LinkedHashSet()) { hex(it, 0) },
            visited = (0 until visited).mapTo(LinkedHashSet()) { hex(it, 0) },
        )
    }

    private val defaultPlace = UUID.fromString("00000000-0000-0000-0000-000000000001")

    private fun walk(n: Int = 0, tiles: Int = 0, metres: Double = 300.0, place: UUID? = null) = Walk(
        startedAt = day(n), endedAt = day(n).plus(1800.0), distance = metres, newTiles = tiles,
        newTilesByPlace = mapOf((place ?: defaultPlace).uuidString to tiles),
    )

    private fun inputs(
        cities: List<City> = emptyList(),
        walks: List<Walk> = emptyList(),
        secrets: Map<String, SwiftDate> = emptyMap(),
        now: SwiftDate? = null,
    ) = Progression.Inputs(cities, walks, secrets, now ?: day(6), perth)

    private fun week(date: SwiftDate = monday) = Progression.week(date, perth)

    private fun points(city: City, xs: List<Double>, start: SwiftDate, gap: Double): List<TrackPoint> = xs.mapIndexed { index, x ->
        val c = city.grid.projection.unproject(offset(city) + Vec2(x, 0.0))
        TrackPoint(c.lat, c.lon, start.epochSeconds + index * gap, 5.0, speed = 1.0)
    }

    @Test
    fun catalogMatchesPricesAndDefaults() {
        assertEquals(21, Progression.catalog.size)
        assertEquals(5, Progression.catalog.count { it.isFree })
        assertEquals(60, Progression.item("spyglass")?.price)
        assertEquals(250, Progression.item("trail.sparkles")?.price)
        assertEquals(5, Ledger().owned.size)
    }

    @Test
    fun mergeUnionsAndKeepsFirstClaimAndLaterEquipment() {
        val first = Ledger(
            purchases = listOf(Ledger.Purchase("a", "spyglass", 60, 10.0)),
            claims = listOf(Ledger.Claim(2, Progression.SHELL_BAG)),
            spyglasses = listOf(Ledger.Spyglass("s1", "secret", listOf(0.0, 1.0), 12.0)),
        ).preparedPicks(150)
        val second = Ledger(
            purchases = listOf(Ledger.Purchase("a", "spyglass", 99, 10.0), Ledger.Purchase("b", "trail.sparkles", 250, 20.0)),
            claims = listOf(Ledger.Claim(2, Progression.SPYGLASS_PAIR), Ledger.Claim(4, Progression.SPYGLASS_PAIR)),
            spyglasses = listOf(Ledger.Spyglass("s1", "different", listOf(2.0, 3.0), 14.0), Ledger.Spyglass("s2", "other", listOf(1.0, 2.0), 15.0)),
            equipped = Ledger.Equipped(trail = "trail.sparkles", updatedAt = 20.0),
        )
        val merged = first.merged(second)
        assertEquals(2, merged.purchases.size)
        assertEquals(60, merged.purchases[0].cost)
        assertEquals(2, merged.claims.size)
        assertEquals(Progression.SHELL_BAG, merged.claims[0].choice)
        assertEquals(2, merged.spyglasses.size)
        assertEquals("secret", merged.spyglasses[0].secretId)
        assertEquals("trail.sparkles", merged.equipped.trail)
        assertEquals(merged, merged.merged(second))
        assertEquals(merged, Codec.ledger(Codec.parse(Codec.sortedKeys(Codec.ledger(merged)))))
    }

    @Test
    fun equipmentClockTiesKeepReceiver() {
        val a = Ledger(equipped = Ledger.Equipped(trail = "trail.footprints"))
        val b = Ledger(equipped = Ledger.Equipped(trail = "trail.sparkles"))
        assertEquals("trail.footprints", a.merged(b).equipped.trail)
    }

    @Test
    fun originalLedgerWithoutOffersStillDecodes() {
        val json = """{"purchases":[],"claims":[],"spyglasses":[],"equipped":{"marker":"marker.dot","trail":"trail.teal","clouds":"clouds.classic","cover":"cover.red","celebration":"celebration.confetti","updatedAt":1790000000}}"""
        val ledger = Codec.ledger(Codec.parse(json))
        assertNull(ledger.offers)
        assertEquals(1_790_000_000.0, ledger.equipped.updatedAt, 0.0)
    }

    @Test
    fun tilesUseIntersectionAndMilestonesAreCumulative() {
        val a = city(visited = 50).let { it.copy(visited = it.visited + hex(999, 0)) } // Non-counting coverage earns nothing.
        val earned = Progression.state(inputs(cities = listOf(a, city(visited = 100)))).earned
        assertEquals(150, earned.tiles)
        assertEquals(100 + 525, earned.milestones)
        assertEquals(0, Progression.state(inputs(cities = listOf(city(visited = 0, total = 0)))).earned.total)
    }

    @Test
    fun secretsAreTenEachAndFutureFindsDontCountYet() {
        val state = Progression.state(inputs(secrets = mapOf("one" to day(0), "two" to day(1), "future" to day(20))))
        assertEquals(20, state.earned.secrets)
    }

    @Test
    fun streakDeduplicatesDaysCapsAndResets() {
        val walks = (0 until 8).map { walk(it) } + listOf(walk(2), walk(9, metres = 299.0), walk(10))
        val state = Progression.state(inputs(walks = walks, now = day(10)))
        assertEquals(125, state.earned.streaks) // 0, 5, 10, 15, 20, 25, 25, 25.
    }

    @Test
    fun streakUsesCalendarDaysAcrossDST() {
        val newYork = ZoneId.of("America/New_York")
        val walks = (0 until 3).map { n ->
            val date = date(LocalDateTime.of(2026, 3, 7, 12, 0).plusDays(n.toLong()), newYork)
            Walk(startedAt = date, endedAt = date.plus(600.0), distance = 300.0)
        }
        val state = Progression.state(Progression.Inputs(walks = walks, now = walks.last().startedAt, zone = newYork))
        assertEquals(15, state.earned.streaks)
    }

    @Test
    fun levelCurveAndPendingPicks() {
        assertEquals(listOf(0, 50, 150, 300, 500, 750, 1050), (1..7).map(Progression::xp))
        for (level in 2..100) {
            assertEquals(level, Progression.level(Progression.xp(level)))
            assertEquals(level - 1, Progression.level(Progression.xp(level) - 1))
        }
        val ledger = Ledger(claims = listOf(Ledger.Claim(2, Progression.SHELL_BAG)))
        assertEquals(listOf(3, 4), Progression.pendingLevels(300, ledger))
        assertTrue(Progression.pendingLevels(0, ledger).isEmpty())
    }

    @Test
    fun picksAreSeededPreferUnownedAndFreezeInLedger() {
        val first = Progression.picks(4)
        assertEquals(first, Progression.picks(4))
        assertEquals(3, first.size)
        assertEquals(3, first.toSet().size)
        assertFalse(first[0] in Progression.picks(4, setOf(first[0])))
        var ledger = Ledger().preparedPicks(300)
        val frozen = ledger.picks(4)
        ledger = ledger.copy(purchases = ledger.purchases + Ledger.Purchase(item = frozen[0], cost = 150, at = 0.0)).preparedPicks(300)
        assertEquals(frozen, ledger.picks(4))
        val other = Ledger(offers = listOf(Ledger.Offer(4, listOf("x", "y", "z"))))
        assertEquals(frozen, ledger.merged(other).picks(4))
        val allOwned = Progression.catalog.mapTo(HashSet()) { it.id }
        assertTrue(Progression.SHELL_BAG in Progression.picks(99, allOwned))
        assertTrue(Progression.SPYGLASS_PAIR in Progression.picks(99, allOwned))
    }

    /**
     * Values printed by the iPhone's own Progression.swift (compiled on a Mac with the
     * Walkies/Model sources), so the seeds, weeks, spyglass rings and sums are pinned to
     * what the iPhone really does rather than to a second reading of its code.
     */
    @Test
    fun matchesValuesFromTheIPhonesCode() {
        val picks = mapOf(
            2 to "trail.footprints,marker.sneaker,shells.50", 3 to "marker.sneaker,celebration.bubbles,marker.boat",
            4 to "cover.map,celebration.bubbles,trail.footprints", 5 to "marker.sneaker,clouds.storm,celebration.bubbles",
            6 to "trail.sparkles,marker.boat,clouds.storm", 7 to "cover.seashell,trail.sparkles,clouds.candy",
            8 to "marker.boat,clouds.sunset,cover.map", 9 to "trail.footprints,cover.gold,cover.seashell",
            10 to "trail.footprints,cover.map,marker.sneaker", 11 to "trail.footprints,cover.gold,clouds.storm",
            12 to "marker.lighthouse,celebration.bubbles,marker.boat",
        )
        for ((level, expected) in picks) assertEquals(expected, Progression.picks(level).joinToString(","))
        val owned = setOf("marker.sneaker", "trail.footprints")
        val ownedPicks = mapOf(
            2 to "shells.50,spyglasses.2,shells.50", 3 to "cover.map,marker.boat,cover.seashell",
            4 to "cover.map,celebration.bubbles,marker.hat", 5 to "cover.seashell,clouds.sunset,marker.lighthouse",
            6 to "clouds.storm,cover.seashell,celebration.fireworks",
        )
        for ((level, expected) in ownedPicks) assertEquals(expected, Progression.picks(level, owned).joinToString(","))
        val quests = mapOf(
            (2026 to 1) to "metres5000,secret,days3", (2026 to 43) to "metres5000,tiles60,secret",
            (2026 to 44) to "tiles60,metres5000,days3", (2027 to 10) to "anotherPlace,tiles25,days3",
            (2030 to 52) to "tiles60,metres5000,days3",
        )
        for ((week, expected) in quests) {
            val kinds = Progression.questKinds(Progression.Week(SwiftDate.distantPast, SwiftDate.distantFuture, week.first, week.second))
            assertEquals(expected, kinds.joinToString(",") { it.id })
        }

        val weeks = mapOf(
            -30 to listOf(1789315200, 1789920000, 2026, 38), 0 to listOf(1792339200, 1792944000, 2026, 43),
            6 to listOf(1792339200, 1792944000, 2026, 43), 7 to listOf(1792944000, 1793548800, 2026, 44),
            75 to listOf(1798387200, 1798992000, 2026, 53), 400 to listOf(1826812800, 1827417600, 2027, 47),
        )
        for ((n, expected) in weeks) {
            val week = week(day(n))
            assertEquals(expected, listOf(week.start.epochSeconds.toInt(), week.end.epochSeconds.toInt(), week.year, week.number))
        }

        fun place(visited: Int, total: Int, id: String) = city(visited, total, UUID.fromString(id))
        val stickered = place(0, 100, "11111111-1111-1111-1111-111111111111").copy(stickers = mapOf("near" to hex(0, 0), "far" to hex(10, 0)))
        val use = Progression.spyglass(stickered, origin, emptyMap(), monday, id = "one")!!
        assertEquals("near", use.secretId)
        assertEquals(-33.638443412857, use.centre[0], 1e-11)
        assertEquals(115.386020818633, use.centre[1], 1e-11)
        assertEquals(1792382400.0, use.at, 1e-6)
        val far = Progression.spyglass(stickered, null, mapOf("near" to monday), monday, id = "two")!!
        assertEquals("far", far.secretId)
        assertEquals(-33.638077289887, far.centre[0], 1e-11)
        assertEquals(115.395249664751, far.centre[1], 1e-11)

        val a = place(50, 100, "22222222-2222-2222-2222-222222222222")
        val b = place(10, 200, "33333333-3333-3333-3333-333333333333")
        val walks = ArrayList<Walk>()
        var k = 0
        fun walkWith(n: Int, tiles: Int, metres: Double, place: UUID) = Walk(
            id = UUID.fromString(String.format(java.util.Locale.US, "00000000-0000-0000-0000-%012d", 100 + k++)),
            startedAt = day(n), endedAt = day(n).plus(1800.0), distance = metres, newTiles = tiles,
            newTilesByPlace = mapOf(place.uuidString to tiles),
        )
        for (n in -60..0 step 2) {
            walks.add(walkWith(n, (n * 7 + 61) % 23, (200 + ((n + 61) * 137) % 3000).toDouble(), if ((n / 2) % 3 == 0) b.id else a.id))
        }
        walks.add(walkWith(1, 4, 900.0, b.id))
        val secrets = mapOf("s1" to day(-40), "s2" to day(-13), "s3" to day(0), "s4" to day(1), "s5" to SwiftDate.distantFuture)
        val state = Progression.state(Progression.Inputs(listOf(a, b), walks, secrets, day(2).plus(3600.0), perth))
        assertEquals(Progression.Earned(tiles = 60, secrets = 40, milestones = 100, streaks = 5, quests = 560), state.earned)
        assertEquals(765, state.xp)
        assertEquals(6, state.level)
        assertEquals("metres5000=3457.0,tiles60=19.0,secret=2.0", state.quests.joinToString(",") { "${it.kind.id}=${it.progress}" })
        assertEquals(
            "2:trail.footprints/marker.sneaker/shells.50 3:marker.sneaker/celebration.bubbles/marker.boat " +
                "4:cover.map/celebration.bubbles/trail.footprints 5:marker.sneaker/clouds.storm/celebration.bubbles " +
                "6:trail.sparkles/marker.boat/clouds.storm",
            Ledger().preparedPicks(state.xp).offers.orEmpty().joinToString(" ") { "${it.level}:${it.choices.joinToString("/")}" },
        )
    }

    @Test
    fun weeksStartMondayEvenForSundayFirstCalendars() {
        val week = week(day(6))
        assertEquals(DayOfWeek.MONDAY, Progression.localDate(week.start, perth).dayOfWeek)
        assertTrue(week.start <= monday && monday < week.end)
        assertEquals(week.end, week(day(7)).start)
        val january = SwiftDate.epoch(LocalDate.of(2027, 1, 1).atStartOfDay(perth).toEpochSecond().toDouble())
        assertEquals(2026, week(january).year)
    }

    @Test
    fun weeklyQuestsAreStableAndProgressUsesOnlyTheirWeek() {
        val week = week()
        assertEquals(Progression.questKinds(week), Progression.questKinds(week))
        assertEquals(3, Progression.questKinds(week).toSet().size)
        val input = inputs(
            walks = listOf(walk(-1, 99, 9000.0), walk(0, 20, 2000.0), walk(1, 15, 2000.0), walk(2, 25, 1000.0), walk(7, 99, 9000.0)),
            secrets = mapOf("a" to day(2), "b" to day(-1)),
        )
        assertEquals(60.0, Progression.questProgress(QuestKind.Tiles25, week, input), 0.0)
        assertEquals(60.0, Progression.questProgress(QuestKind.Tiles60, week, input), 0.0)
        assertEquals(1.0, Progression.questProgress(QuestKind.Secret, week, input), 0.0)
        assertEquals(3.0, Progression.questProgress(QuestKind.Days3, week, input), 0.0)
        assertEquals(5000.0, Progression.questProgress(QuestKind.Metres5000, week, input), 0.0)
        val completed = Progression.quests(week, input).count { it.isComplete }
        assertTrue(completed >= 2)
        assertTrue(Progression.state(input).earned.quests >= completed * 40)
    }

    @Test
    fun anotherPlaceUsesTheFavouriteAtWeekStart() {
        val a = city(visited = 50)
        val b = city(visited = 10)
        val week = week()
        val prior = walk(-2, tiles = 50, place = a.id)
        val input = inputs(cities = listOf(a, b), walks = listOf(prior, walk(0, tiles = 10, place = b.id)))
        assertEquals(1.0, Progression.questProgress(QuestKind.AnotherPlace, week, input), 0.0)
        val same = inputs(cities = listOf(a, b), walks = listOf(prior, walk(0, tiles = 10, place = a.id)))
        assertEquals(0.0, Progression.questProgress(QuestKind.AnotherPlace, week, same), 0.0)
    }

    @Test
    fun priorQuestRewardsDontDisappearNextMonday() {
        val input = inputs(walks = listOf(walk(0, 60, 5000.0), walk(1), walk(2)), secrets = mapOf("a" to day(1)))
        val next = inputs(walks = input.walks, secrets = input.foundSecrets, now = day(7))
        assertEquals(Progression.state(input).earned.quests, Progression.state(next).earned.quests)
        assertTrue(Progression.state(next).quests.all { it.progress == 0.0 })
    }

    @Test
    fun balanceOwnsPurchasesAndKeepsOfflineDebt() {
        val ledger = Ledger(
            purchases = listOf(Ledger.Purchase(item = "trail.sparkles", cost = 250, at = 0.0)),
            claims = listOf(Ledger.Claim(2, Progression.SHELL_BAG), Ledger.Claim(3, "cover.gold")),
        )
        assertEquals(250, ledger.spent)
        assertEquals(100, ledger.balance(300))
        assertEquals(-200, ledger.balance(0))
        assertTrue("trail.sparkles" in ledger.owned)
        assertTrue("cover.gold" in ledger.owned)
        assertFalse("spyglass" in ledger.owned)
    }

    @Test
    fun spyglassCountsOnlyConsumablesAndUses() {
        var ledger = Ledger(
            purchases = listOf(Ledger.Purchase(item = "spyglass", cost = 60, at = 0.0)),
            claims = listOf(Ledger.Claim(2, Progression.SPYGLASS_PAIR)),
        )
        assertEquals(3, ledger.spyglassesLeft)
        ledger = ledger.copy(spyglasses = listOf(Ledger.Spyglass(secretId = "a", centre = listOf(0.0, 1.0), at = 1.0)))
        assertEquals(2, ledger.spyglassesLeft)
    }

    @Test
    fun spyglassIsNearestSeededAndExpiresOrEndsWhenFound() {
        val place = city(visited = 0).copy(stickers = mapOf("near" to hex(0, 0), "far" to hex(10, 0)))
        val use = Progression.spyglass(place, origin, emptyMap(), monday, id = "one")!!
        val again = Progression.spyglass(place, origin, emptyMap(), day(1), id = "two")!!
        assertEquals("near", use.secretId)
        assertEquals(use.centre, again.centre)
        assertTrue(Coordinate(use.centre[0], use.centre[1]).distance(origin) <= 120.1)
        val ledger = Ledger(spyglasses = listOf(use))
        val ring = Progression.activeRing(place, ledger, emptyMap(), monday)!!
        assertEquals(125.0, ring.radius, 0.0)
        assertNull(Progression.activeRing(place, ledger, emptyMap(), monday.plus(10800.0)))
        assertNull(Progression.activeRing(place, ledger, mapOf("near" to monday), monday))
        assertNull(Progression.spyglass(place, null, mapOf("near" to monday, "far" to monday), monday))
        assertNull(Progression.activeRing(city(visited = 0), ledger, emptyMap(), monday))
    }

    @Test
    fun oneWalkReportsShellsXPAndQuestGains() {
        val place = city(visited = 9)
        val before = inputs(cities = listOf(place), walks = listOf(walk(-1)), now = day(0))
        val visited = place.copy(visited = place.visited + hex(9, 0))
        val after = inputs(cities = listOf(visited), walks = before.walks + walk(0, tiles = 1), secrets = mapOf("new" to day(0)), now = day(0))
        val earned = Progression.walkEarnings(before, after)
        assertEquals(1, earned.breakdown.tiles)
        assertEquals(20, earned.breakdown.milestones)
        assertEquals(10, earned.breakdown.secrets)
        assertEquals(5, earned.breakdown.streaks)
        assertEquals(earned.breakdown.total, earned.shells)
        assertEquals(earned.shells, earned.xp)
        assertTrue(earned.quests.isNotEmpty())
        assertTrue(earned.quests.all { it.gained > 0 })
    }

    @Test
    fun questRewardsAreExactlyFortyPerCompletedQuest() {
        val input = inputs(walks = listOf(walk(0, 60, 5000.0), walk(1), walk(2)), secrets = mapOf("a" to day(1)))
        val completed = Progression.quests(week(), input).count { it.isComplete }
        assertEquals(completed * 40, Progression.state(input).earned.quests)
    }

    @Test
    fun recapCarriesTheComputedWalkRewards() {
        val place = city(visited = 10)
        val recap = WalkRecap.make(
            walk(0, tiles = 1), listOf(place), mapOf(place.id to setOf(hex(9, 0))),
            mapOf("new" to day(0).plus(60.0)), listOf(walk(-1)), now = day(0).plus(3600.0).epochSeconds,
        )
        assertEquals(1, recap.earnings.breakdown.tiles)
        assertEquals(20, recap.earnings.breakdown.milestones)
        assertEquals(10, recap.earnings.breakdown.secrets)
        assertEquals(5, recap.earnings.breakdown.streaks)
        assertEquals(recap.earnings.breakdown.total, recap.shells)
        assertEquals(recap.shells, recap.xp)
    }

    @Test
    fun anotherPlaceUsesStoredCoverageWhenOldWalksAreMissing() {
        val a = city(visited = 50)
        val b = city(visited = 10)
        val input = inputs(cities = listOf(a, b), walks = listOf(walk(0, tiles = 10, place = b.id)))
        assertEquals(1.0, Progression.questProgress(QuestKind.AnotherPlace, week(), input), 0.0)
    }

    @Test
    fun legacyRoutesRecoverOnlyNewTilesAndCanBeCached() {
        val place = city(visited = 2)
        val first = walk(-1, tiles = 1).let { it.copy(newTilesByPlace = null, points = points(place, listOf(0.0, 15.0), it.startedAt, 20.0)) }
        val second = walk(0, tiles = 1).let { it.copy(newTilesByPlace = null, points = points(place, listOf(0.0, 15.0, 30.0, 45.0, 60.0, 75.0, 90.0), it.startedAt, 20.0)) }
        val input = inputs(cities = listOf(place), walks = listOf(first, second))
        val counts = Progression.placeTileCounts(input)
        assertEquals(1, counts[first.id]?.get(place.id))
        assertEquals(1, counts[second.id]?.get(place.id))
        val original = Progression.state(input)
        val cached = input.copy(newTilesByWalk = counts)
        assertEquals(original.earned, Progression.state(cached).earned)
        assertEquals(original.quests, Progression.state(cached).quests)
    }

    @Test
    fun duplicatePhoneCoverageCountsEachTileOnlyInItsFirstWeek() {
        val place = city(visited = 40)
        val hexes = (0 until 40).mapTo(HashSet()) { hex(it, 0) }
        val first = walk(0, 40, 3000.0, place.id).copy(newTileHexesByPlace = mapOf(place.id.uuidString to hexes))
        var duplicate = first.copy(id = UUID.randomUUID(), startedAt = first.startedAt.plus(30.0), endedAt = first.endedAt?.plus(30.0))
        val week = week()
        var input = inputs(cities = listOf(place), walks = listOf(duplicate, first))
        assertEquals(40.0, Progression.questProgress(QuestKind.Tiles60, week, input), 0.0)
        assertEquals(3000.0, Progression.questProgress(QuestKind.Metres5000, week, input), 0.0)
        assertEquals(Progression.state(inputs(cities = listOf(place), walks = listOf(first))).earned, Progression.state(input).earned)
        val recovered = Progression.backfill(input.walks, input.cities)
        assertTrue(recovered.walks.all { it.newTilesByPlace?.get(place.id.uuidString) == 40 })
        val saved = recovered.walks.map { Codec.walk(Codec.parse(Codec.sortedKeys(Codec.walk(it)))) }
        input = input.copy(walks = saved, newTilesByWalk = Progression.backfill(saved, listOf(place)).counts)
        assertEquals(40.0, Progression.questProgress(QuestKind.Tiles60, week, input), 0.0)
        // A repeat in a later week cannot earn the same first-discovery credit.
        duplicate = duplicate.copy(startedAt = day(7), endedAt = day(7).plus(1800.0))
        input = inputs(cities = listOf(place), walks = listOf(first, duplicate), now = day(8))
        assertEquals(0.0, Progression.questProgress(QuestKind.Tiles25, week(day(7)), input), 0.0)
    }

    @Test
    fun countOnlyHistoryRecoversTileIdentitiesOnceForSyncDeduplication() {
        val place = city(visited = 2)
        val base = walk(0, 2, place = place.id)
        val first = base.copy(points = points(place, listOf(0.0, 90.0), base.startedAt, 40.0))
        val duplicate = first.copy(id = UUID.randomUUID(), startedAt = first.startedAt.plus(1.0))
        val replays = ArrayList<UUID>()
        val backfill = Progression.backfill(listOf(duplicate, first), listOf(place)) { replays.add(it) }
        assertEquals(setOf(first.id, duplicate.id), replays.toSet())
        assertEquals(2, backfill.counts.values.sumOf { it.values.sum() })
        assertTrue(backfill.walks.all { it.newTilesByPlace?.get(place.id.uuidString) == 2 })
        val saved = backfill.walks.map { Codec.walk(Codec.parse(Codec.sortedKeys(Codec.walk(it)))) }
        replays.clear()
        assertEquals(backfill.counts, Progression.backfill(saved, listOf(place)) { replays.add(it) }.counts)
        assertTrue(replays.isEmpty())
    }

    @Test
    fun distanceOverlapUsesLongerOutingAndStrictHalfOfShorterRange() {
        val first = walk(0, metres = 3000.0)
        var duplicate = first.copy(id = UUID.randomUUID(), startedAt = first.startedAt.plus(600.0), endedAt = first.endedAt?.plus(600.0), distance = 3200.0)
        val separate = first.copy(id = UUID.randomUUID(), startedAt = first.startedAt.plus(3600.0), endedAt = first.endedAt?.plus(3600.0), distance = 2000.0)
        val input = inputs(walks = listOf(first, duplicate, separate))
        assertEquals(5200.0, Progression.questProgress(QuestKind.Metres5000, week(), input), 0.0)
        assertEquals(
            Progression.distinctOutings(input.walks).map { it.id },
            Progression.distinctOutings(listOf(separate, duplicate, first)).map { it.id },
        )
        duplicate = duplicate.copy(startedAt = first.startedAt.plus(900.0), endedAt = first.endedAt?.plus(900.0))
        assertEquals(2, Progression.distinctOutings(listOf(first, duplicate)).size)
        // A short recording wholly inside a longer outing is also a duplicate.
        duplicate = duplicate.copy(startedAt = first.startedAt.plus(100.0), endedAt = first.startedAt.plus(200.0))
        assertEquals(1, Progression.distinctOutings(listOf(first, duplicate)).size)
    }

    @Test
    fun overlappingDeviceRecordingsMergeTransitivelyAndAcrossWeeks() {
        val start = week().start.plus(-600.0)
        val first = Walk(startedAt = start, endedAt = start.plus(1800.0), distance = 3000.0)
        val bridge = Walk(startedAt = start.plus(600.0), endedAt = start.plus(2400.0), distance = 2900.0)
        val third = Walk(startedAt = start.plus(1200.0), endedAt = start.plus(3000.0), distance = 2800.0)
        assertEquals(listOf(first.id), Progression.distinctOutings(listOf(third, bridge, first)).map { it.id })
        val input = inputs(walks = listOf(third, first, bridge))
        assertEquals(0.0, Progression.questProgress(QuestKind.Metres5000, week(), input), 0.0)
        assertEquals(3000.0, Progression.questProgress(QuestKind.Metres5000, week(start), input), 0.0)
    }

    @Test
    fun weeklyDistanceMatchesDeduplicatingEveryWalk() {
        val rng = SplitMix64(7)
        val walks = ArrayList<Walk>()
        val first = week().start.plus(-21 * 24 * 3600.0)
        repeat(160) {
            // Clustered around midnights, with second phones recording the same outing.
            val day = java.lang.Long.remainderUnsigned(rng.next(), 42).toDouble()
            val start = first.plus(day * 24 * 3600 + (rng.unit() - 0.5) * 4 * 3600)
            val length = 300 + rng.unit() * 5400
            walks.add(Walk(startedAt = start, endedAt = start.plus(length), distance = 200 + rng.unit() * 4000))
            if (rng.unit() < 0.4) {
                val shift = (rng.unit() - 0.5) * length
                walks.add(Walk(startedAt = start.plus(shift), endedAt = start.plus(shift + length * (0.5 + rng.unit())), distance = 200 + rng.unit() * 4000))
            }
        }
        walks.add(Walk(startedAt = first.plus(20 * 24 * 3600.0), distance = 9000.0))
        val now = first.plus(38 * 24 * 3600.0)
        for (offset in -1 until 7) {
            val week = week(first.plus(offset * 7 * 24 * 3600.0 + 3600))
            val everything = Progression.distinctOutings(walks.filter { it.endedAt != null && it.startedAt <= now })
                .filter { it.startedAt >= week.start && it.startedAt < week.end }
                .fold(0.0) { total, walk -> total + walk.distance }
            assertEquals(everything, Progression.weeklyDistance(week, walks.shuffled(), now), 1e-9)
        }
    }

    @Test
    fun discardedCoverageKeepsWeekStartFavouriteAndWeeklyTileCredit() {
        val favourite = city(visited = 100, total = 200)
        val hexes = (90 until 110).mapTo(HashSet()) { hex(it, 0) }
        val other = city(visited = 110, total = 200).copy(tileCredits = listOf(City.TileCredit(UUID.randomUUID(), day(0), hexes)))
        val week = week()
        var input = inputs(cities = listOf(favourite, other))
        assertEquals(20.0, Progression.questProgress(QuestKind.Tiles25, week, input), 0.0)
        assertEquals(1.0, Progression.questProgress(QuestKind.AnotherPlace, week, input), 0.0)
        assertEquals(0.0, Progression.questProgress(QuestKind.Days3, week, input), 0.0)
        assertEquals(0.0, Progression.questProgress(QuestKind.Metres5000, week, input), 0.0)
        assertEquals(0, Progression.state(input).earned.streaks)
        val inFavourite = walk(0, tiles = 1, place = favourite.id).copy(newTileHexesByPlace = mapOf(favourite.id.uuidString to setOf(hex(99, 0))))
        input = input.copy(walks = listOf(inFavourite))
        assertEquals(1.0, Progression.questProgress(QuestKind.AnotherPlace, week, input), 0.0)
        // Both phones finding the discarded coverage doesn't duplicate the credit.
        val duplicate = walk(1, tiles = 20, place = other.id).copy(newTileHexesByPlace = mapOf(other.id.uuidString to hexes))
        input = input.copy(walks = input.walks + duplicate)
        assertEquals(21.0, Progression.questProgress(QuestKind.Tiles25, week, input), 0.0)
        input = input.copy(cities = Codec.cities(Codec.parse(Codec.sortedKeys(Codec.cities(input.cities)))))
        assertEquals(21.0, Progression.questProgress(QuestKind.Tiles25, week, input), 0.0)
        val before = Progression.state(input).earned.quests
        input = input.copy(now = day(7))
        assertEquals(before, Progression.state(input).earned.quests)
    }

    @Test
    fun lastFixSecretAppearsInAutomaticRecapRewardsAndQuestTick() {
        // Pick a week containing the secret quest so this pins the tick as well.
        val start = (0 until 52).map { day(it * 7) }.first { QuestKind.Secret in Progression.questKinds(week(it)) }
        val entry = LoreLibrary.all.first()
        val hex = hex(0, 0)
        val place = city(visited = 1).copy(stickers = mapOf(entry.id to hex))
        val end = start.plus(600.0)
        val walk = Walk(
            startedAt = start, endedAt = end, distance = 300.0, newTiles = 1,
            newTilesByPlace = mapOf(place.id.uuidString to 1), newTileHexesByPlace = mapOf(place.id.uuidString to setOf(hex)), automatic = true,
        )
        val recap = WalkRecap.make(
            walk, listOf(place), mapOf(place.id to setOf(hex)), mapOf(entry.id to end.plus(0.1)), emptyList(),
            now = end.plus(1.0).epochSeconds, counts = emptyMap(),
        )
        assertEquals(listOf(entry.id), recap.secrets.map { it.entry.id })
        assertEquals(10, recap.earnings.breakdown.secrets)
        assertEquals(40, recap.earnings.breakdown.quests)
        assertTrue(recap.questProgress.any { it.kind == QuestKind.Secret && it.completed })
        assertEquals(recap.earnings.breakdown.total, recap.xp)
    }

    @Test
    fun equipmentFromALosingOfflineClaimFallsBackWithoutChangingLedger() {
        var ledger = Ledger(equipped = Ledger.Equipped(trail = "trail.sparkles", updatedAt = 20.0))
        assertEquals("trail.teal", ledger.resolvedEquipment.trail)
        assertEquals("trail.sparkles", ledger.equipped.trail)
        ledger = ledger.copy(claims = ledger.claims + Ledger.Claim(2, "trail.sparkles"))
        assertEquals("trail.sparkles", ledger.resolvedEquipment.trail)
        assertEquals(20.0, ledger.resolvedEquipment.updatedAt, 0.0)
    }

    @Test
    fun mixedSavedAndLegacyWalksKeepCountsAndOnlyRecoverTheRequiredPrefix() {
        val place = city(visited = 2)
        val saved = walk(-2, tiles = 1, place = place.id).copy(newTileHexesByPlace = mapOf(place.id.uuidString to setOf(hex(0, 0))))
        val legacy = walk(-1, tiles = 1).let { it.copy(newTilesByPlace = null, points = points(place, listOf(0.0, 90.0), it.startedAt, 40.0)) }
        val tail = walk(0, tiles = 99, place = place.id)
        val replays = ArrayList<UUID>()
        val recovered = Progression.backfill(listOf(tail, legacy, saved), listOf(place)) { replays.add(it) }
        assertEquals(listOf(legacy.id), replays)
        assertEquals(1, recovered.counts[saved.id]?.get(place.id))
        assertEquals(1, recovered.counts[legacy.id]?.get(place.id))
        assertEquals(99, recovered.counts[tail.id]?.get(place.id))
        val persisted = recovered.walks.map { Codec.walk(Codec.parse(Codec.sortedKeys(Codec.walk(it)))) }
        replays.clear()
        assertEquals(recovered.counts, Progression.backfill(persisted, listOf(place)) { replays.add(it) }.counts)
        assertTrue(replays.isEmpty())
    }

    @Test
    fun mixedOldCountOnlyPrefixIsRecoveredOnceWithoutOverwritingSavedCounts() {
        val place = city(visited = 2)
        val saved = walk(-1, tiles = 1, place = place.id).let { it.copy(points = points(place, listOf(0.0, 15.0), it.startedAt, 40.0)) }
        val legacy = walk(0, tiles = 1).let { it.copy(newTilesByPlace = null, points = points(place, listOf(0.0, 90.0), it.startedAt, 40.0)) }
        val replays = ArrayList<UUID>()
        val recovered = Progression.backfill(listOf(saved, legacy), listOf(place)) { replays.add(it) }
        assertEquals(listOf(saved.id, legacy.id), replays)
        assertEquals(1, recovered.counts[saved.id]?.get(place.id))
        assertEquals(1, recovered.counts[legacy.id]?.get(place.id))
        replays.clear()
        Progression.backfill(recovered.walks, listOf(place)) { replays.add(it) }
        assertTrue(replays.isEmpty())
    }

    @Test
    fun recapDoesNotReawardMilestoneWhenWalkAddsACountingTile() {
        val fresh = hex(-1, 0)
        val place = city(visited = 10).let { it.copy(tiles = it.tiles + fresh, visited = it.visited + fresh) }
        val walk = walk(0, tiles = 1, place = place.id).copy(addedTilesByPlace = mapOf(place.id.uuidString to setOf(fresh)))
        val recap = WalkRecap.make(walk, listOf(place), mapOf(place.id to setOf(fresh)), emptyMap(), emptyList(), counts = emptyMap())
        assertEquals(0, recap.earnings.breakdown.milestones)
        assertEquals(1, recap.earnings.breakdown.tiles)
        assertEquals(1, recap.shells)
        assertEquals(0.1, recap.places.first().before, 1e-12)
        assertEquals(100, recap.before.first().tiles.size)
    }

    @Test
    fun exploredSecretsAreFoundWithoutRewardingShellsOrQuests() {
        val found = mapOf("explored" to Progression.exploredSecretDate, "walked" to day(0))
        val input = inputs(secrets = found)
        assertEquals(10, Progression.state(input).earned.secrets)
        assertEquals(1.0, Progression.questProgress(QuestKind.Secret, week(), input), 0.0)
    }

    @Test
    fun historicalRewardsCanBeReusedWhileLiveTileAndCurrentQuestProgressChanges() {
        val favourite = city(visited = 50)
        val other = city(visited = 10)
        var input = inputs(cities = listOf(favourite, other), walks = listOf(walk(-14, 60, 5000.0, other.id)))
        input = input.copy(newTilesByWalk = Progression.placeTileCounts(input))
        val history = Progression.historicalRewards(input)
        val before = Progression.state(input)
        input = input.copy(
            historicalRewards = history,
            cities = listOf(favourite, other.copy(visited = other.visited + hex(10, 0))),
            unrecordedTilesByPlace = mapOf(other.id to 1),
        )
        val after = Progression.state(input)
        assertEquals(before.earned.tiles + 1, after.earned.tiles)
        assertEquals(before.earned.quests, after.earned.quests)
        assertEquals(before.earned.streaks, after.earned.streaks)
        assertEquals(history.questsByWeek, Progression.historicalRewards(input).questsByWeek)
    }

    @Test
    fun progressionHomeCalendarKeepsSundayWalksAndLifetimeXPStableWhenTravelling() {
        val sunday = date(LocalDateTime.of(2026, 10, 25, 23, 30), perth)
        val tokyo = ZoneId.of("Asia/Tokyo")
        assertNotEquals(Progression.week(sunday, Progression.zone), Progression.week(sunday, tokyo))
        val walk = Walk(startedAt = sunday, endedAt = sunday.plus(600.0), distance = 5000.0, newTiles = 60, newTilesByPlace = emptyMap())
        val input = Progression.Inputs(walks = listOf(walk), foundSecrets = mapOf("secret" to sunday), now = sunday.plus(86400.0))
        assertEquals("Australia/Perth", input.zone.id)
        val state = Progression.state(input)
        val completed = Progression.quests(Progression.week(sunday, Progression.zone), input).count { it.isComplete }
        assertEquals(completed * 40, state.earned.quests)
        // Device calendars never enter the default production inputs.
        assertEquals(Progression.zone, Progression.Inputs().zone)
    }

    @Test
    fun aWeekNeverGetsBothTileQuests() {
        for (year in 2026..2030) {
            for (number in 1..52) {
                val kinds = Progression.questKinds(Progression.Week(SwiftDate.distantPast, SwiftDate.distantFuture, year, number))
                assertEquals(3, kinds.toSet().size)
                assertFalse(QuestKind.Tiles25 in kinds && QuestKind.Tiles60 in kinds)
            }
        }
    }

    // LevelMeterTests.swift

    @Test
    fun startsAtLevelOneAndClampsNegativeXP() {
        val meter = LevelMeter(-10)
        assertEquals(1, meter.level)
        assertEquals(0, meter.start)
        assertEquals(50, meter.end)
        assertEquals(0.0, meter.fraction, 0.0)
    }

    @Test
    fun measuresWithinTheCurrentLevelRatherThanLifetimeXP() {
        val meter = LevelMeter(100)
        assertEquals(2, meter.level)
        assertEquals(50, meter.start)
        assertEquals(150, meter.end)
        assertEquals(0.5, meter.fraction, 0.0)
    }

    @Test
    fun fillsEveryCrossedLevelAndEndsOnAnEmptyNewLevel() {
        assertEquals(
            listOf(LevelMeter.Fill(1, 0.5, 1.0), LevelMeter.Fill(2, 0.0, 1.0), LevelMeter.Fill(3, 0.0, 0.0)),
            LevelMeter.fills(25, 150),
        )
    }

    @Test
    fun partialAndUnchangedWalksHaveOneBar() {
        assertEquals(listOf(LevelMeter.Fill(2, 0.25, 0.5)), LevelMeter.fills(75, 100))
        assertEquals(listOf(LevelMeter.Fill(2, 0.5, 0.5)), LevelMeter.fills(100, 100))
        assertEquals(listOf(LevelMeter.Fill(2, 0.5, 0.5)), LevelMeter.fills(100, 20))
    }

    @Test
    fun startsAtAnExactThresholdAndFinishesPartWayThroughAHigherLevel() {
        assertEquals(listOf(LevelMeter.Fill(2, 0.0, 1.0), LevelMeter.Fill(3, 0.0, 0.5)), LevelMeter.fills(50, 225))
    }
}
