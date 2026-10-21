package com.mikecann.walkies.place

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Sample OSM ways, by their tags. Keep in step with convex/placeData.test.ts and WalkableRuleTests.swift. */
class WalkableRuleTest {
    private val walkable = listOf(
        mapOf("highway" to "residential"),
        mapOf("highway" to "footway"),
        mapOf("highway" to "footway", "footway" to "sidewalk"),
        mapOf("highway" to "cycleway", "maxspeed" to "80"),
        mapOf("highway" to "secondary", "maxspeed" to "60"),
        mapOf("highway" to "primary", "sidewalk" to "both"),
        mapOf("highway" to "primary", "sidewalk" to "left"),
        mapOf("highway" to "trunk", "sidewalk" to "separate"),
        mapOf("highway" to "trunk_link", "sidewalk:left" to "yes"),
        mapOf("highway" to "primary_link", "sidewalk:both" to "separate"),
        mapOf("highway" to "trunk", "foot" to "designated"),
        mapOf("highway" to "primary", "foot" to "permissive"),
        mapOf("highway" to "primary", "footway" to "sidewalk"),
        mapOf("highway" to "trunk", "foot" to "yes", "maxspeed" to "100"),
        mapOf("highway" to "secondary", "maxspeed" to "90", "sidewalk" to "right"),
        mapOf("highway" to "tertiary", "maxspeed" to "40 mph"),
        mapOf("highway" to "unclassified", "maxspeed" to "AU:rural"),
    )
    private val unwalkable = listOf(
        mapOf("highway" to "motorway"),
        mapOf("highway" to "motorway_link", "sidewalk" to "both"),
        mapOf("highway" to "trunk"),
        mapOf("highway" to "trunk_link"),
        mapOf("highway" to "primary"),
        mapOf("highway" to "primary_link"),
        mapOf("highway" to "primary", "sidewalk" to "no"),
        mapOf("highway" to "trunk", "sidewalk" to "none", "sidewalk:left" to "no"),
        mapOf("highway" to "secondary", "maxspeed" to "80"),
        mapOf("highway" to "tertiary", "maxspeed" to "100 km/h"),
        mapOf("highway" to "unclassified", "maxspeed" to "50 mph"),
        mapOf("highway" to "secondary", "maxspeed" to "80", "foot" to "permissive"),
        mapOf("highway" to "residential", "access" to "private"),
        mapOf("highway" to "service", "foot" to "no"),
        mapOf("highway" to "construction"),
        emptyMap(),
    )

    @Test
    fun busyRoadsOnlyCountWithAFootpathOrAnOpenInvitation() {
        for (tags in walkable) assertEquals(tags.toString(), true, WalkableRule.isWalkable(tags))
        for (tags in unwalkable) assertEquals(tags.toString(), false, WalkableRule.isWalkable(tags))
    }

    @Test
    fun speedLimitsReadKmhAndMph() {
        assertEquals(80.0, WalkableRule.speedLimit("80")!!, 0.0)
        assertEquals(80.0, WalkableRule.speedLimit("80 km/h")!!, 0.0)
        assertEquals(70.0, WalkableRule.speedLimit(" 70kmh")!!, 0.0)
        assertEquals(80.47, WalkableRule.speedLimit("50 mph")!!, 0.01)
        assertNull(WalkableRule.speedLimit("none"))
        assertNull(WalkableRule.speedLimit("AU:urban"))
        assertNull(WalkableRule.speedLimit(null))
    }
}
