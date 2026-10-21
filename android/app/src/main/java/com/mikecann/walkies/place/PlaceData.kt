package com.mikecann.walkies.place

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlin.math.abs

/** A street, path or track from OpenStreetMap, with the tags we use. */
data class OSMWay(val tags: Map<String, String>, val points: List<Coordinate>)

/**
 * The compact shared OSM file in Convex storage (CachedPlaceData.swift). Boundary
 * coordinates use GeoJSON's [lon, lat]; street points use [lat, lon]. Validated,
 * so a malformed cache is an error rather than lost tiles.
 */
data class PlaceData(
    val boundary: Boundary,
    val ways: List<OSMWay>,
    /**
     * The street cache's version (WalkableRule.VERSION), from places:get rather than
     * the file. Null from a server older than version 2, whose ways weren't filtered.
     */
    val version: Int? = null,
) {
    class Invalid : Exception("Invalid cached OSM geometry")

    /** What a place built from these streets records as City.streetsVersion. */
    val streetsVersion: Int? get() = version?.takeIf { it >= WalkableRule.VERSION }?.let { WalkableRule.VERSION }

    companion object {
        /** The server's shared street file for this OSM relation (CachedPlaceData.fetch). */
        suspend fun fetch(osmId: Long, client: ConvexClient): PlaceData {
            val file = client.action("places:get", buildJsonObject { put("osmId", osmId) }) as? JsonObject ?: throw Invalid()
            val url = (file["url"] as? JsonPrimitive)?.contentOrNull ?: throw Invalid()
            val version = (file["version"] as? JsonPrimitive)?.intOrNull
            val bytes = client.download(url)
            return withContext(Dispatchers.Default) { parse(bytes.decodeToString()).copy(version = version) }
        }

        fun parse(text: String): PlaceData {
            val root = Json.parseToJsonElement(text).jsonObject
            val polygons = root.array("boundary")
            if (polygons.isEmpty()) throw Invalid()
            val boundary = Boundary(polygons.map { polygon ->
                val rings = polygon.jsonArray
                val outer = rings.firstOrNull()?.jsonArray ?: throw Invalid()
                if (!rings.all { it.jsonArray.size >= 4 }) throw Invalid()
                GeoPolygon(
                    outer = outer.map { coordinate(it.jsonArray, geoJSON = true) },
                    holes = rings.drop(1).map { hole -> hole.jsonArray.map { coordinate(it.jsonArray, geoJSON = true) } },
                )
            })
            val ways = root.array("ways").map { element ->
                val way = element.jsonObject
                val highway = way.string("highway")
                if (highway.isNullOrEmpty()) throw Invalid()
                val tags = linkedMapOf("highway" to highway)
                for (key in listOf("footway", "service", "access", "foot")) way.string(key)?.let { tags[key] = it }
                OSMWay(tags, way.array("points").map { coordinate(it.jsonArray, geoJSON = false) })
            }
            return PlaceData(boundary, ways)
        }

        private fun JsonObject.array(key: String): JsonArray = this[key] as? JsonArray ?: throw Invalid()

        private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

        private fun coordinate(pair: JsonArray, geoJSON: Boolean): Coordinate {
            if (pair.size != 2) throw Invalid()
            val a = (pair[0] as? JsonPrimitive)?.doubleOrNull ?: throw Invalid()
            val b = (pair[1] as? JsonPrimitive)?.doubleOrNull ?: throw Invalid()
            val lat = if (geoJSON) b else a
            val lon = if (geoJSON) a else b
            if (!lat.isFinite() || !lon.isFinite() || abs(lat) > 90 || abs(lon) > 180) throw Invalid()
            return Coordinate(lat, lon)
        }
    }
}
