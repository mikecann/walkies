package com.mikecann.walkies

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.grid.Vec2
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.CityBuilder
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.PlaceData
import com.mikecann.walkies.store.Store
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/**
 * Always-on and button walks through the model: ModelFixesTests.swift and the walk
 * parts of ProgressionIntegrationTests.swift. Both phones put off finishing a walk
 * until the saved history's tile counts are worked out; these models work them out
 * before the constructor returns, so walks finish straight away. The progression
 * parts are in ProgressionModelTest.
 */
class AppModelTest {
    private var now = 1_790_000_000.0
    private val clock = { now }

    private fun city(name: String = "Test place", visited: Int = 0, origin: Coordinate = Coordinate(12.345, 45.678)): City {
        val base = HexGrid.hex(containing = origin)
        val ring = listOf(Vec2(-1000.0, -1000.0), Vec2(1000.0, -1000.0), Vec2(1000.0, 1000.0), Vec2(-1000.0, 1000.0))
            .map { HexGrid.projection.unproject(HexGrid.centre(base) + it) }
        return City(
            name = name, detail = "Tests",
            boundary = Boundary(listOf(GeoPolygon(ring, emptyList()))),
            tiles = (0 until 100).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            visited = (0 until visited).mapTo(LinkedHashSet()) { Hex(base.q + it, base.r) },
            roads = emptyList(),
        )
    }

    private fun coordinate(city: City, x: Double): Coordinate {
        val centre = HexGrid.centre(HexGrid.hex(containing = city.boundary.centre))
        return HexGrid.projection.unproject(centre + Vec2(x, 0.0))
    }

    private fun visit(model: AppModel, city: City, x: Double, seconds: Double, speed: Double = 1.0, wheels: Boolean = false) {
        val c = coordinate(city, x)
        model.record(TrackPoint(c.lat, c.lon, now + seconds, 5.0, speed = speed, wheels = wheels))
    }

    private fun model(store: Store, alwaysOn: Boolean, location: FakeLocation = FakeLocation()) =
        AppModel(store, FakeSettings(alwaysOn = alwaysOn), location, clock = clock)

    @Test
    fun anAutomaticWalkKeepsTheFixItStartedFrom() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        val model = model(store, alwaysOn = true)
        val xs = listOf(-400.0, -350.0, -300.0, -250.0, -200.0, -150.0, -100.0)
        for ((i, x) in xs.withIndex()) visit(model, place, x, i * 40.0)
        val walk = model.activeWalk!!
        assertFalse(model.autoWalkPending)
        assertEquals(xs.size, walk.points.size)
        assertTrue(walk.points[0].coordinate.distance(coordinate(place, -400.0)) < 1)
        assertTrue(abs(walk.startedAt.epochSeconds - walk.points[0].time) < 0.001)
        // Recording and replaying agree on the distance and the tiles.
        assertTrue(abs(walk.distance - CoverageTracer.distance(walk.points)) < 0.01)
        val straight = coordinate(place, -400.0).distance(coordinate(place, -100.0))
        assertTrue(abs(walk.distance - straight) < 1)
        val samples = CoverageTracer.samples(walk.points)
        val traced = samples.map { HexGrid.hex(containing = it) }.toSet()
        assertTrue(traced.containsAll(model.freshTiles[place.id].orEmpty()))
        // The route starts with the first segment, a sample's spacing from the first fix.
        assertTrue(samples.first().distance(coordinate(place, -400.0)) <= CoverageTracer.SPACING)
    }

    @Test
    fun fixesAfterTheGapNeverJoinTheWalkBeforeIt() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        val start = now - 300
        val points = listOf(-200.0, 0.0).mapIndexed { index, x ->
            val c = coordinate(place, x)
            TrackPoint(c.lat, c.lon, start + index * 80, 5.0, speed = 1.0)
        }
        val old = Walk(startedAt = SwiftDate.epoch(start), points = points, distance = 200.0, automatic = true)
        store.save(old)
        val model = model(store, alwaysOn = true)
        assertEquals(old.id, model.activeWalk?.id)
        for ((i, x) in listOf(100.0, 150.0, 200.0).withIndex()) visit(model, place, x, 400 + i * 40.0)
        val next = model.activeWalk!!
        assertNotEquals(old.id, next.id)
        assertTrue(next.points.all { it.time > now + 300 })
        // The old one was 200 m in a straight jump, too far between fixes to count as walked,
        // so it isn't kept as a walk.
        assertTrue(model.walks.none { it.id == old.id })
        assertTrue(store.loadWalks().none { it.id == old.id })
    }

    @Test
    fun aDriveEndsTheWalkEvenWhenTheArrivalFixLooksOnFoot() {
        val (store, _) = tempStore()
        val place = city(origin = Coordinate(-33.65, 45.678))
        store.save(listOf(place))
        val model = model(store, alwaysOn = true)
        for (i in 0..8) visit(model, place, i * 50.0, i * 40.0)
        val old = model.activeWalk!!
        assertFalse(model.autoWalkPending)
        val last = old.points.last()
        val arrivalTime = last.time - now + 519
        visit(model, place, 2900.0, arrivalTime, speed = 1.2)
        // One fix on its own could be a GPS glitch, so nothing happens yet.
        assertEquals(old.id, model.activeWalk?.id)
        assertTrue(model.walks.isEmpty())
        visit(model, place, 2950.0, arrivalTime + 40)
        val saved = model.walks.single()
        assertEquals(old.id, saved.id)
        assertEquals(old.points, saved.points)
        assertEquals(SwiftDate.epoch(last.time), saved.endedAt)
        assertEquals(saved.endedAt, store.loadWalks().single().endedAt)
        for (i in 2..4) visit(model, place, 2900.0 + i * 50, arrivalTime + i * 40)
        val next = model.activeWalk!!
        assertNotEquals(old.id, next.id)
        assertTrue(next.points.first().coordinate.distance(coordinate(place, 2900.0)) < 1)
        assertEquals(SwiftDate.epoch(now + arrivalTime), next.startedAt)
        assertTrue(next.points.all { it.coordinate.distance(coordinate(place, 2900.0)) < 250 })
        assertTrue(next.points.zipWithNext().all { (a, b) -> a.time < b.time })
    }

    @Test
    fun whileTheStepCountComesInTheNextWalkStillStartsWhereYouArrived() {
        val (store, _) = tempStore()
        val place = city(origin = Coordinate(-33.65, 45.678))
        store.save(listOf(place))
        var reply: ((Int?) -> Unit)? = null
        val model = AppModel(store, FakeSettings(alwaysOn = true), FakeLocation(), clock = clock, stepQuery = { _, _, done -> reply = done })
        for (i in 0..8) visit(model, place, i * 50.0, i * 40.0)
        val old = model.activeWalk!!
        val arrivalTime = old.points.last().time - now + 519
        visit(model, place, 2900.0, arrivalTime, speed = 1.2)
        visit(model, place, 2950.0, arrivalTime + 40)
        assertTrue(model.walks.isEmpty())
        reply!!(100)
        assertEquals(old.id, model.walks.single().id)
        assertEquals(100, model.walks.single().steps)
        visit(model, place, 3000.0, arrivalTime + 80)
        val next = model.activeWalk!!
        assertTrue(next.points.first().coordinate.distance(coordinate(place, 2900.0)) < 1)
        assertEquals(SwiftDate.epoch(now + arrivalTime), next.startedAt)
    }

    @Test
    fun aRideWithALongWaitStillEndsTheWalk() {
        for (wheels in listOf(true, false)) {
            val (store, _) = tempStore()
            val place = city(origin = Coordinate(-33.65, 45.678))
            store.save(listOf(place))
            val model = model(store, alwaysOn = true)
            for (i in 0..8) visit(model, place, i * 50.0, i * 40.0)
            val old = model.activeWalk!!
            assertFalse(model.autoWalkPending)
            val last = old.points.last()
            val lastTime = last.time - now
            // Ride evidence close by must wait until you've gone more than maxGap.
            visit(model, place, 450.0, lastTime + 20, speed = if (wheels) 1.0 else 8.0, wheels = wheels)
            assertEquals(old.id, model.activeWalk?.id)
            assertEquals(old.points, model.activeWalk?.points)
            val arrivalTime = lastTime + 400
            assertTrue(last.coordinate.distance(coordinate(place, 900.0)) / 400 < CoverageTracer.MAX_SPEED)
            visit(model, place, 900.0, arrivalTime)
            visit(model, place, 950.0, arrivalTime + 40)
            assertEquals(old.id, model.walks.single().id)
            assertEquals(old.points, model.walks.single().points)
            assertEquals(SwiftDate.epoch(last.time), model.walks.single().endedAt)
            val next = model.activeWalk!!
            assertNotEquals(old.id, next.id)
            assertTrue(next.points.first().coordinate.distance(coordinate(place, 900.0)) < 1)
            // Ride evidence from the previous walk mustn't split this walking dropout.
            visit(model, place, 1150.0, arrivalTime + 220)
            visit(model, place, 1200.0, arrivalTime + 260)
            assertEquals(next.id, model.activeWalk?.id)
            assertTrue(model.activeWalk!!.points.last().coordinate.distance(coordinate(place, 1200.0)) < 1)
        }
    }

    @Test
    fun aWalkingGPSDropoutKeepsTheSameWalk() {
        val (store, _) = tempStore()
        val place = city(origin = Coordinate(-33.65, 45.678))
        store.save(listOf(place))
        val model = model(store, alwaysOn = true)
        for (i in 0..8) visit(model, place, i * 50.0, i * 40.0)
        val old = model.activeWalk!!
        assertFalse(model.autoWalkPending)
        val lastTime = old.points.last().time - now
        visit(model, place, 600.0, lastTime + 180)
        visit(model, place, 650.0, lastTime + 220)
        assertTrue(model.walks.isEmpty())
        assertEquals(old.id, model.activeWalk?.id)
        assertEquals(old.startedAt, model.activeWalk?.startedAt)
        assertTrue(model.activeWalk!!.points.last().coordinate.distance(coordinate(place, 650.0)) < 1)
    }

    @Test
    fun oneWildFixMidWalkKeepsTheSameWalk() {
        val (store, _) = tempStore()
        val place = city(origin = Coordinate(-33.65, 45.678))
        store.save(listOf(place))
        val model = model(store, alwaysOn = true)
        for (i in 0..8) visit(model, place, i * 50.0, i * 40.0)
        val old = model.activeWalk!!
        val lastTime = old.points.last().time - now
        visit(model, place, 700.0, lastTime + 5, speed = 9.0)
        for (i in 1..3) visit(model, place, 400.0 + i * 50, lastTime + 5 + i * 40)
        assertTrue(model.walks.isEmpty())
        assertEquals(old.id, model.activeWalk?.id)
        assertTrue(model.activeWalk!!.points.last().coordinate.distance(coordinate(place, 550.0)) < 1)
    }

    @Test
    fun confirmedShortAutomaticOutingPersistsOnlyTileCredit() {
        val (store, root) = tempStore()
        store.save(listOf(city(visited = 0)))
        val model = model(store, alwaysOn = true)
        val place = model.cities[0]
        // Each segment is within accuracy/speed/gap limits. Displacement from
        // the first stored fix reaches 150 m, but traced distance stays below 300 m.
        for ((i, x) in listOf(-400.0, -350.0, -300.0, -250.0, -200.0, -150.0).withIndex()) visit(model, place, x, i * 40.0)
        assertNotNull(model.activeWalk)
        assertFalse(model.autoWalkPending)
        val fresh = model.freshTiles[place.id].orEmpty()
        assertTrue(fresh.isNotEmpty())
        // The next fix closes the old outing through the normal inactivity path.
        visit(model, place, -100.0, 1000.0)
        assertNull(model.activeWalk)
        assertTrue(model.walks.isEmpty())
        assertTrue(store.loadWalks().isEmpty())
        assertEquals(fresh, model.cities[0].tileCredits?.first()?.hexes)
        val reopened = model(Store(root), alwaysOn = false)
        val credit = reopened.cities[0].tileCredits!!.first()
        assertEquals(fresh, credit.hexes)
        assertEquals(model.cities[0].tileCredits!!.first().at, credit.at)
    }

    @Test
    fun resumedWalkKeepsFreshHexes() {
        val (store, _) = tempStore()
        val fresh = setOf(Hex(HexGrid.hex(containing = Coordinate(12.345, 45.678)).q - 1, HexGrid.hex(containing = Coordinate(12.345, 45.678)).r))
        val base = city(visited = 10)
        val place = base.copy(tiles = base.tiles + fresh, visited = base.visited + fresh)
        store.save(listOf(place))
        val start = now - 300
        val points = listOf(-200.0, 0.0).mapIndexed { index, x ->
            val c = coordinate(place, x)
            TrackPoint(c.lat, c.lon, start + index * 80, 5.0, speed = 1.0)
        }
        val id = place.id.uuidString
        val walk = Walk(
            startedAt = SwiftDate.epoch(start), points = points, distance = 200.0, newTiles = 1,
            newTilesByPlace = mapOf(id to 1), newTileHexesByPlace = mapOf(id to fresh), addedTilesByPlace = mapOf(id to fresh),
            automatic = true,
        )
        store.save(walk)
        val model = model(store, alwaysOn = true)
        assertEquals(walk.id, model.activeWalk?.id)
        assertEquals(fresh, model.freshTiles[place.id])
        model.endAutoWalk()
        assertEquals(1, model.walks.first().newTilesByPlace?.get(id))
        assertEquals(fresh, model.walks.first().addedTilesByPlace?.get(id))
    }

    @Test
    fun aPendingWalkUncoversNothingUntilItsGotFarEnough() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        val model = model(store, alwaysOn = true)
        var i = 0
        while (model.pendingWalkDistance < 140) {
            visit(model, place, -400.0 + i * 20, i * 15.0)
            i++
        }
        assertTrue(model.autoWalkPending)
        assertTrue(model.cities[0].visited.isEmpty())
        assertTrue(model.activePath.isEmpty())
        while (model.autoWalkPending) {
            visit(model, place, -400.0 + i * 20, i * 15.0)
            i++
        }
        val walk = model.activeWalk!!
        assertTrue(model.cities[0].visited.isNotEmpty())
        // Everything since it started, in one go.
        assertEquals(CoverageTracer.samples(walk.points), model.activePath)
        assertEquals(model.cities[0].visited.size, walk.newTiles)
    }

    @Test
    fun aWalkYouStartRecordsEveryFixAndSavesItsTiles() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        val location = FakeLocation(LocationAccess.Authorization.NotDetermined)
        val model = model(store, alwaysOn = false, location = location)
        model.startWalk()
        assertNull(model.activeWalk)
        assertEquals(1, location.requests)
        location.authorization = LocationAccess.Authorization.Allowed
        model.authorizationChanged()
        assertNotNull(model.activeWalk)
        for (i in 0 until 20) visit(model, place, -400.0 + i * 15, i * 12.0)
        visit(model, place, 2000.0, 300.0) // A jump: kept, but not walked.
        assertEquals(21, model.activeWalk!!.points.size)
        model.endWalk()
        val walk = store.loadWalks().single()
        assertNull(walk.automatic)
        assertTrue(walk.newTiles > 0)
        assertEquals(walk.newTiles, walk.newTilesByPlace!![place.id.uuidString])
        assertEquals(model.cities[0].visited, walk.newTileHexesByPlace!![place.id.uuidString])
        assertTrue(abs(walk.distance - coordinate(place, -400.0).distance(coordinate(place, -400.0 + 19 * 15))) < 1)
    }

    @Test
    fun anUnfinishedWalkIsClosedAtItsLastFixWhenNotAlwaysOn() {
        val (store, _) = tempStore()
        val place = city()
        store.save(listOf(place))
        val c = coordinate(place, 0.0)
        val walk = Walk(startedAt = SwiftDate.epoch(now - 900), points = listOf(TrackPoint(c.lat, c.lon, now - 600, 5.0)))
        store.save(walk)
        val model = model(store, alwaysOn = false)
        assertNull(model.activeWalk)
        assertEquals(SwiftDate.epoch(now - 600), model.walks.single().endedAt)
        assertEquals(SwiftDate.epoch(now - 600), store.loadWalks().single().endedAt)
    }

    @Test
    fun walkingTheSimulatorRouteThroughGeographeUncoversItsStreets() {
        val (store, _) = tempStore()
        val data = PlaceData.parse(File(repoRoot(), "shared/fixtures/places/geographe.json").readText())
        val place = CityBuilder.build("Geographe", "Busselton", null, data.boundary, data.ways)
        val model = model(store, alwaysOn = true)
        model.add(place)
        // What android/scripts/sim-walk.sh feeds the emulator: a fix every 2 s at 1.4 m/s.
        val route = File(repoRoot(), "scripts/routes/navigation-way.txt").readLines().filter { it.isNotBlank() }.map {
            val (lat, lon) = it.split(",").map(String::toDouble)
            Coordinate(lat, lon)
        }
        var t = 0.0
        for ((a, b) in route.zipWithNext()) {
            val steps = maxOf(1, (a.distance(b) / 2.8).toInt())
            for (i in 0 until steps) {
                val p = a.lerp(b, i.toDouble() / steps)
                model.record(TrackPoint(p.lat, p.lon, now + t, 5.0, speed = 1.4))
                t += 2
            }
        }
        assertFalse(model.autoWalkPending)
        assertTrue(model.cities[0].visited.size > 5)
        assertTrue(model.activeWalk!!.distance > 300)
        model.endAutoWalk()
        assertEquals(1, store.loadWalks().size)
    }
}
