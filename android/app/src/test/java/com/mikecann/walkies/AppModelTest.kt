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
 * parts of ProgressionIntegrationTests.swift. The iPhone defers finishing a walk
 * until history is ready; there's no history backfill on Android yet, so it's
 * always ready and finishes straight away.
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

    private fun visit(model: AppModel, city: City, x: Double, seconds: Double) {
        val c = coordinate(city, x)
        model.record(TrackPoint(c.lat, c.lon, now + seconds, 5.0, speed = 1.0))
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
