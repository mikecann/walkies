package com.mikecann.walkies

import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.store.Store
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.io.File

/** These events are also replayed by the Swift model suite. */
class WalkLifecycleTest {
    @Test fun sharedLifecycleScenarios() {
        val fixture = Json.parseToJsonElement(File(repoRoot(), "shared/fixtures/walk-lifecycle.json").readText()).jsonObject
        assertEquals(1, fixture.getValue("version").jsonPrimitive.int)
        val start = fixture.getValue("startTime").jsonPrimitive.double
        val origin = fixture.getValue("origin").jsonObject
        val lat = origin.getValue("lat").jsonPrimitive.double
        val lon = origin.getValue("lon").jsonPrimitive.double
        for (scenario in fixture.getValue("scenarios").jsonArray) {
            val spec = scenario.jsonObject
            val name = spec.getValue("name").jsonPrimitive.content
            val (store, root) = tempStore()
            try {
                var now = start
                val settings = FakeSettings(alwaysOn = true)
                var model = AppModel(store, settings, FakeLocation(), clock = { now })
                fun fix(x: Double, elapsed: Double, wheels: Boolean = false, speed: Double = 1.0, accuracy: Double = 5.0) {
                    now = start + elapsed
                    model.record(TrackPoint(lat + x / 111195.0, lon, now, accuracy, speed = speed, wheels = wheels))
                }
                val initial = fixture.getValue("initial").jsonObject
                for ((i, x) in initial.getValue("xs").jsonArray.withIndex()) {
                    fix(x.jsonPrimitive.double, i * initial.getValue("interval").jsonPrimitive.double)
                }
                val original = requireNotNull(model.activeWalk)
                assertFalse(name, model.autoWalkPending)
                model.saveNow(waiting = true)
                for (event in spec.getValue("events").jsonArray) {
                    val e = event.jsonObject
                    e["time"]?.let { now = start + it.jsonPrimitive.double }
                    when (e.getValue("action").jsonPrimitive.content) {
                        "fix" -> fix(e.getValue("x").jsonPrimitive.double, now - start,
                            e["wheels"]?.jsonPrimitive?.boolean ?: false,
                            e["speed"]?.jsonPrimitive?.double ?: 1.0,
                            e["accuracy"]?.jsonPrimitive?.double ?: 5.0)
                        "advance" -> Unit
                        "checkpoint" -> model.saveNow(waiting = true)
                        "relaunch" -> {
                            store.flush()
                            model = AppModel(Store(root), settings, FakeLocation(), clock = { now })
                        }
                        "finish" -> model.endAutoWalk()
                        "stale" -> model.finishStaleAutoWalk()
                        else -> error("Unknown lifecycle event: $e")
                    }
                }
                val expected = spec.getValue("expected").jsonObject
                when (expected.getValue("active").jsonPrimitive.content) {
                    "same" -> assertEquals(name, original.id, model.activeWalk?.id)
                    "different" -> { assertNotNull(name, model.activeWalk); assertNotEquals(name, original.id, model.activeWalk?.id) }
                    "none" -> assertNull(name, model.activeWalk)
                }
                assertEquals(name, expected.getValue("finished").jsonPrimitive.int, model.walks.size)
                expected["points"]?.let { assertEquals(name, it.jsonPrimitive.int, model.activeWalk!!.points.size) }
                expected["startTime"]?.let { assertEquals(name, start + it.jsonPrimitive.double, model.activeWalk!!.startedAt.epochSeconds, 0.001) }
                expected["distance"]?.let { assertEquals(name, it.jsonPrimitive.double, model.activeWalk!!.distance, 0.01) }
                expected["endTime"]?.let {
                    val ended = model.walks.single()
                    assertEquals(name, original.id, ended.id)
                    assertEquals(name, start + it.jsonPrimitive.double, ended.endedAt!!.epochSeconds, 0.001)
                    assertEquals(name, original.points, ended.points)
                }
                expected["finishedDistance"]?.let { assertEquals(name, it.jsonPrimitive.double, model.walks.single().distance, 0.01) }
                model.saveNow(waiting = true)
                assertEquals(name, model.walks + listOfNotNull(model.activeWalk), Store(root).loadWalks())
            } finally { root.parentFile.deleteRecursively() }
        }
    }
}
