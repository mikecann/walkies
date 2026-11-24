package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.LegacyFinish
import com.mikecann.walkies.model.LegacyNextWalk
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.WalkEndReason
import com.mikecann.walkies.model.WalkStage
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.store.Store
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/**
 * docs/walk-lifecycle.md: a walk closes the moment it ends, and saved places only ever
 * hold finished walks (SealedWalkTests.swift). These cover the moments around closing that
 * older versions got wrong: steps that come back late or never, the app stopping between
 * writes, two outings over the same tiles, and files older versions left open.
 */
class SealedWalkLifecycleTest {
    private val start = 100_000.0
    private var now = start

    private fun point(x: Double, elapsed: Double) = TrackPoint(12.345 + x / 111195, 45.678, start + elapsed, 5.0, speed = 1.0)

    private fun place() = City(
        name = "Lifecycle", detail = "Tests",
        boundary = Boundary(listOf(GeoPolygon(listOf(Coordinate(12.32, 45.65), Coordinate(12.37, 45.65),
            Coordinate(12.37, 45.70), Coordinate(12.32, 45.70)), emptyList()))),
        tiles = (0..180).map { HexGrid.hex(containing = point(it * 10.0, 0.0).coordinate) }.toSet(),
        visited = emptySet(), roads = emptyList(),
    )

    /** Walks always on through [xs] (metres), one fix every 40 s from [from] seconds. */
    private fun walk(model: AppModel, xs: List<Double>, from: Double) {
        for ((i, x) in xs.withIndex()) {
            val fix = point(x, from + i * 40)
            now = fix.time
            model.record(fix)
        }
    }

    private fun appModel(store: Store, alwaysOn: Boolean, stepQuery: ((SwiftDate, SwiftDate, (Int?) -> Unit) -> Unit)? = null) =
        AppModel(store, FakeSettings(alwaysOn = alwaysOn), FakeLocation(), clock = { now }, stepQuery = stepQuery)

    @Test fun theStageMovesMatchTheSharedTable() {
        val table = Json.parseToJsonElement(File(repoRoot(), "shared/fixtures/walk-stages.json").readText()).jsonObject
        assertEquals(WalkStage.entries.map { it.rawValue }.toSet(),
            table.getValue("stages").jsonArray.map { it.jsonPrimitive.content }.toSet())
        assertEquals(WalkStage.Event.entries.map { it.rawValue }.toSet(),
            table.getValue("events").jsonArray.map { it.jsonPrimitive.content }.toSet())
        val allowed = HashMap<String, String?>()
        for (move in table.getValue("moves").jsonArray) {
            val m = move.jsonObject
            allowed["${m.getValue("from").jsonPrimitive.content} ${m.getValue("event").jsonPrimitive.content}"] =
                m.getValue("to").jsonPrimitive.contentOrNull
        }
        for (stage in WalkStage.entries) for (event in WalkStage.Event.entries) {
            val key = "${stage.rawValue} ${event.rawValue}"
            assertEquals(key, key in allowed, stage.allows(event))
            if (key in allowed) assertEquals(key, allowed[key], stage.after(event)?.rawValue)
            else assertNull(key, stage.after(event))
        }
    }

    @Test fun aWalkClosesStraightAwayAndItsStepsFillInLater() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place()))
            val replies = ArrayList<(Int?) -> Unit>()
            val model = appModel(store, alwaysOn = true) { _, _, done -> replies += done }
            val changed = ArrayList<java.util.UUID>()
            model.walksChanged = { changed += it }
            walk(model, (0..10).map { it * 50.0 }, from = 0.0)
            val first = model.activeWalk!!
            // Ten minutes later you set off again from the same spot.
            walk(model, (0..4).map { 500.0 + it * 50 }, from = 1100.0)
            val closed = model.walks.single { it.id == first.id }
            assertEquals(WalkStage.Done, closed.stage)
            assertNotNull(closed.endedAt)
            assertNull(closed.steps)
            assertEquals(true, closed.stepsPending)
            assertNotEquals(first.id, model.activeWalk?.id)
            assertEquals(model.walks[0].newTileHexesByPlace!!.values.first(), Store(root).loadCities()[0].visited)
            assertEquals(1, replies.size)
            replies[0](1234)
            assertEquals(1234, model.walks.first().steps)
            assertNull(model.walks.first().stepsPending)
            assertEquals(1234, Store(root).loadWalks().first { it.id == first.id }.steps)
            assertEquals(listOf(first.id), changed)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun stepsStillOutstandingWhenTheAppStopsAreAskedForAgain() {
        val (store, root) = tempStore()
        try {
            var reply: ((Int?) -> Unit)? = null
            val model = appModel(store, alwaysOn = false) { _, _, done -> reply = done }
            model.startWalk()
            val id = model.activeWalk!!.id
            model.endWalk()
            assertNotNull(reply)
            // The app stops before the phone answers.
            val relaunched = appModel(Store(root), alwaysOn = false) { _, _, done -> done(42) }
            assertEquals(listOf(id), relaunched.walks.map { it.id })
            assertEquals(42, relaunched.walks.first().steps)
            assertNull(relaunched.walks.first().stepsPending)
            reply!!(7)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aWalkSealedJustBeforeTheAppStoppedReachesTheSavedPlacesOnce() {
        for (placesSaved in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                var place = place()
                val points = (0..8).map { point(it * 50.0, it * 40.0) }
                val (preview, fresh) = place.visit(CoverageTracer.samples(points), place.shape())
                assertTrue(fresh.isNotEmpty())
                if (placesSaved) place = preview
                store.save(listOf(place)); store.flush()
                val sealed = Walk(startedAt = SwiftDate.epoch(start), endedAt = SwiftDate.epoch(start + 320), points = points,
                    distance = CoverageTracer.distance(points), newTiles = fresh.size,
                    newTilesByPlace = mapOf(place.id.uuidString to fresh.size), newTileHexesByPlace = mapOf(place.id.uuidString to fresh),
                    addedTilesByPlace = emptyMap(), automatic = true, stage = WalkStage.Sealed)
                store.save(sealed)
                val model = appModel(store, alwaysOn = false)
                assertEquals("placesSaved=$placesSaved", fresh, model.cities[0].visited)
                assertEquals(fresh, Store(root).loadCities()[0].visited)
                assertEquals(listOf(sealed.id), model.walks.map { it.id })
                assertEquals(WalkStage.Done, Store(root).loadWalks().single().stage)
                assertEquals(fresh.size, model.questTileCounts[sealed.id]?.get(place.id))
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun aShortOutingSealedJustBeforeTheAppStoppedKeepsOneTileCredit() {
        for (placesSaved in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                var place = place()
                val points = (0..4).map { point(it * 40.0, it * 40.0) }
                val (preview, fresh) = place.visit(CoverageTracer.samples(points), place.shape())
                val short = Walk(startedAt = SwiftDate.epoch(start), endedAt = SwiftDate.epoch(start + 160), points = points,
                    newTileHexesByPlace = mapOf(place.id.uuidString to fresh), addedTilesByPlace = emptyMap(),
                    automatic = true, stage = WalkStage.Sealed, short = true)
                if (placesSaved) place = preview.copy(tileCredits = listOf(City.TileCredit(short.id, short.startedAt, fresh)))
                store.save(listOf(place)); store.flush()
                store.save(short)
                val model = appModel(store, alwaysOn = false)
                assertTrue(model.walks.isEmpty())
                assertTrue(Store(root).loadWalks().isEmpty())
                assertEquals(1, model.cities[0].tileCredits.orEmpty().count { it.id == short.id })
                assertEquals(1, Store(root).loadCities()[0].tileCredits.orEmpty().count { it.id == short.id })
                assertEquals(fresh, Store(root).loadCities()[0].visited)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    @Test fun savedPlacesNeverHoldTheOpenWalksTiles() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place()))
            val model = appModel(store, alwaysOn = true)
            walk(model, (0..10).map { it * 50.0 }, from = 0.0)
            assertFalse(model.autoWalkPending)
            assertTrue(model.cities[0].visited.isNotEmpty())
            model.saveNow(waiting = true)
            assertTrue(Store(root).loadCities()[0].visited.isEmpty())
            assertEquals(place().tiles, Store(root).loadCities()[0].tiles)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun theEarlierOfTwoOutingsOverTheSameTilesGetsTheCredit() {
        val (store, root) = tempStore()
        try {
            store.save(listOf(place()))
            var model = appModel(store, alwaysOn = true)
            val route = (0..10).map { it * 50.0 }
            walk(model, route, from = 0.0)
            val first = model.activeWalk!!.id
            // The same route again after a break, with the app stopped partway through.
            walk(model, route.take(6), from = 1100.0)
            val second = model.activeWalk!!.id
            assertNotEquals(first, second)
            model.saveNow(waiting = true)
            now += 30
            model = appModel(Store(root), alwaysOn = true)
            assertEquals(second, model.activeWalk?.id)
            walk(model, route.drop(6), from = now - start + 40)
            now += 700
            model.finishStaleAutoWalk()
            assertNull(model.activeWalk)
            val credit = model.walks.associate { it.id to it.newTiles }
            assertTrue(credit.getValue(first) > 0)
            assertEquals(0, credit.getValue(second))
            assertEquals(model.walks.single { it.id == first }.newTileHexesByPlace!!.values.first(), Store(root).loadCities()[0].visited)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aWalkYouStartedIsClosedAsYoursAfterARelaunch() {
        val (store, root) = tempStore()
        try {
            val model = appModel(store, alwaysOn = false)
            model.startWalk()
            val id = model.activeWalk!!.id
            assertEquals(WalkStage.Walking, model.activeWalk!!.stage)
            model.saveNow(waiting = true)
            assertEquals(WalkStage.Walking, Store(root).loadWalks().single { it.id == id }.stage)
            val relaunched = appModel(Store(root), alwaysOn = false)
            // Not always on, so it can't carry on by itself: it's closed and kept.
            assertNull(relaunched.activeWalk)
            assertEquals(listOf(id), relaunched.walks.map { it.id })
            assertEquals(WalkStage.Done, relaunched.walks.single().stage)
            assertEquals(WalkEndReason.Recovered, relaunched.walks.single().endReason)
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aRecordingWalkIsTracedAgainOnRelaunchAndItsTilesStayOutOfSavedPlaces() {
        val (store, root) = tempStore()
        try {
            val place = place()
            store.save(listOf(place))
            val points = (0..4).map { point(it * 50.0, 720 + it * 40.0) }
            val open = Walk(startedAt = SwiftDate.epoch(start + 720), points = points, automatic = true,
                stage = WalkStage.Walking, resumeAnchor = points.last())
            store.save(open)
            now = start + 900
            val model = appModel(store, alwaysOn = true)
            assertEquals(open.id, model.activeWalk?.id)
            assertFalse(model.autoWalkPending)
            assertTrue(model.cities[0].visited.isNotEmpty())
            assertEquals(model.cities[0].visited, model.freshTiles[place.id])
            model.saveNow(waiting = true)
            assertTrue(Store(root).loadCities()[0].visited.isEmpty())
            model.endAutoWalk()
            assertNull(model.activeWalk)
            assertEquals(model.cities[0].visited, Store(root).loadCities()[0].visited)
            val saved = Store(root).loadWalks().single { it.id == open.id }
            assertEquals(WalkStage.Done, saved.stage)
            assertEquals(model.cities[0].visited, saved.newTileHexesByPlace!![place.id.uuidString])
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun aFinishThatAnOlderVersionLeftWaitingClosesBothOutingsAtLaunch() {
        for (restartExpired in listOf(false, true)) {
            val (store, root) = tempStore()
            try {
                val points = (0..8).map { point(it * 50.0, it * 40.0) }
                val next = LegacyNextWalk(arrival = point(900.0, 720.0), point = point(950.0, 760.0),
                    following = (2..7).map { point(900.0 + it * 50, 720.0 + it * 40) })
                val old = Walk(startedAt = SwiftDate.epoch(start), points = points, newTileHexesByPlace = emptyMap(), automatic = true,
                    pendingFinish = LegacyFinish(SwiftDate.epoch(start + 320), WalkEndReason.Rode, byYou = false, successor = next))
                store.save(old)
                now = start + if (restartExpired) 1700 else 1010
                val model = appModel(store, alwaysOn = restartExpired)
                assertNull(model.activeWalk)
                assertEquals(setOf(old.id, next.id), model.walks.map { it.id }.toSet())
                assertTrue(model.walks.all { it.endedAt != null && it.stage == WalkStage.Done && it.pendingFinish == null })
                assertTrue(Store(root).loadWalks().all { it.stage == WalkStage.Done })
                assertEquals(start + 320, model.walks.single { it.id == old.id }.endedAt!!.epochSeconds, 0.001)
                assertEquals(WalkEndReason.Rode, model.walks.single { it.id == old.id }.endReason)
            } finally { root.parentFile.deleteRecursively() }
        }
    }

    /** Walk JSON goes up whole and the other phone reads it, so the names match WalkStage.swift and Walk.swift. */
    @Test fun stageMetadataRoundTripsAndOldFilesStillLoad() {
        val old = Codec.walk(Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0}"""))
        assertNull(old.stage); assertNull(old.rideSeen); assertNull(old.resumeAnchor)
        assertTrue(old.isLegacyOpen)
        val ended = old.copy(endedAt = SwiftDate(200.0))
        assertEquals(WalkStage.Done, ended.currentStage)
        assertFalse(ended.isLegacyOpen)
        // Older versions on either phone also saved a continuation, which is no longer read.
        val olderAndroid = Codec.walk(Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"points":[],"distance":0,"newTiles":0,"continuation":"rode"}"""))
        assertEquals(old, olderAndroid)
        // As the new iPhone version writes it.
        val iPhone = Codec.walk(Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":100,"endedAt":300,"points":[],"distance":0,"newTiles":0,"automatic":true,"stage":"done","rideSeen":true,"short":true,"stepsPending":true,"endReason":"rode"}"""))
        assertEquals(WalkStage.Done, iPhone.stage)
        assertEquals(true, iPhone.rideSeen); assertEquals(true, iPhone.short); assertEquals(true, iPhone.stepsPending)
        val keys = Codec.walk(iPhone).keys
        assertTrue(keys.containsAll(listOf("stage", "rideSeen", "short", "stepsPending", "endReason")))
        assertEquals("done", Codec.walk(iPhone)["stage"]!!.jsonPrimitive.content)
        var walk = Walk(startedAt = SwiftDate.epoch(start), automatic = true, stage = WalkStage.Tentative, rideSeen = true,
            resumeAnchor = point(900.0, 720.0))
        val saved = Codec.walk(Codec.walk(walk))
        assertEquals(walk, saved)
        walk = walk.moved(WalkStage.Event.Confirmed)!!
        assertEquals(WalkStage.Walking, walk.stage)
        assertNull(walk.moved(WalkStage.Event.Committed))
    }

    @Test fun legacyFinishesStillReadWithoutARecursiveWalk() {
        val seed = LegacyNextWalk(arrival = point(900.0, 720.0), point = point(950.0, 760.0), following = listOf(point(1000.0, 800.0)))
        val original = Walk(startedAt = SwiftDate.epoch(0.0),
            pendingFinish = LegacyFinish(SwiftDate.epoch(320.0), WalkEndReason.Rode, false, seed))
        assertEquals(original, Codec.walk(Codec.walk(original)))
        assertEquals(3, seed.walk().points.size)
        assertEquals(100.0, seed.walk().distance, 0.01)
        // The extra fields older versions saved on each carried outing are skipped.
        val olderSeed = Codec.walk(Codec.parse("""{"id":"A1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5","startedAt":0,"points":[],"distance":0,"newTiles":0,
            "pendingFinish":{"at":320,"reason":"rode","byYou":false,"successor":{"id":"B1A1A1A1-B2B2-4C3C-8D4D-E5E5E5E5E5E5",
            "arrival":{"lat":1,"lon":2,"time":720,"accuracy":5},"continuation":"rode","endReason":"gap"}}}"""))
        assertEquals(1, olderSeed.pendingFinish!!.carried.single().points.size)
    }
}
