package com.mikecann.walkies.place

/**
 * Which OSM ways you could walk along (WalkableRule in OSMClient.swift). Keep this in
 * step with isWalkable in convex/placeData.ts, which filters the shared street cache.
 * Motorways and private ways are out. Trunk and primary roads, and anything signed
 * 80 km/h or more, are out unless they have a footpath or are open to walkers.
 * Footpaths mapped alongside them are separate ways and stay in as normal.
 */
object WalkableRule {
    /**
     * Places built from streets filtered by this rule. Matches the street cache's
     * version in convex/places.ts; a place built with less has its tiles redone once.
     */
    const val VERSION = 2

    val EXCLUDED_HIGHWAYS = setOf("motorway", "motorway_link", "construction", "proposed", "raceway", "bus_guideway", "abandoned", "razed")
    private val busyRoads = setOf("trunk", "trunk_link", "primary", "primary_link")
    private val pathTypes = setOf("footway", "path", "cycleway", "pedestrian", "steps", "bridleway", "corridor")
    private val sidewalkValues = setOf("both", "left", "right", "yes", "separate")

    fun isWalkable(tags: Map<String, String>): Boolean {
        val highway = tags["highway"] ?: return false
        if (highway in EXCLUDED_HIGHWAYS) return false
        if (tags["access"] in setOf("private", "no") || tags["foot"] in setOf("private", "no")) return false
        val sidewalk = tags["sidewalk"] in sidewalkValues ||
            listOf("sidewalk:left", "sidewalk:right", "sidewalk:both").any { tags[it] in setOf("yes", "separate") }
        val foot = tags["foot"]
        val walkersWelcome = foot == "yes" || foot == "designated"
        if (highway in busyRoads && !sidewalk && !walkersWelcome && foot != "permissive" && tags["footway"] != "sidewalk") return false
        val limit = speedLimit(tags["maxspeed"])
        if (highway !in pathTypes && limit != null && limit >= 80 && !sidewalk && !walkersWelcome) return false
        return true
    }

    /** km/h from an OSM maxspeed ("80", "80 km/h", "50 mph"), or null for "none", "AU:urban" and the like. */
    fun speedLimit(maxspeed: String?): Double? {
        val text = maxspeed?.trim()?.lowercase() ?: return null
        val digits = text.takeWhile { it.isDigit() || it == '.' }
        val value = digits.toDoubleOrNull() ?: return null
        return when (text.drop(digits.length).trim()) {
            "", "km/h", "kmh", "kph" -> value
            "mph" -> value * 1.609344
            else -> null
        }
    }
}
