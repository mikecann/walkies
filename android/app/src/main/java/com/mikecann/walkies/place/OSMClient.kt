package com.mikecann.walkies.place

import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.LocalProjection
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.URLEncoder
import java.util.Locale

/** A place with a boundary, from OpenStreetMap (PlaceResult in OSMClient.swift). */
data class PlaceResult(
    /** Nominatim's place_id. */
    val id: Long,
    val name: String,
    val detail: String,
    /** What OSM calls it: suburb, town, city, municipality... */
    val kind: String,
    val boundary: Boundary,
    /** Square metres. */
    val area: Double,
    /** OSM relation id, distinct from Nominatim's place_id. Null in older nearby.json files. */
    val osmId: Long? = null,
) {
    /** "Suburb · 4.2 km²". */
    val summary: String
        get() = "${kind.replaceFirstChar { it.titlecase(Locale.getDefault()) }} · ${areaText(area)}"

    companion object {
        /** Format.area in Theme.swift. */
        fun areaText(squareMetres: Double): String {
            val km2 = squareMetres / 1_000_000
            return if (km2 < 10) String.format(Locale.US, "%.1f km²", km2) else "${Math.round(km2)} km²"
        }
    }
}

/** Suburbs around your places, so the map can offer them without asking OpenStreetMap every launch (Store.swift). */
data class NearbyPlaces(
    val south: Double,
    val west: Double,
    val north: Double,
    val east: Double,
    val fetchedAt: SwiftDate,
    val places: List<PlaceResult>,
) {
    fun covers(south: Double, west: Double, north: Double, east: Double) =
        this.south <= south && this.west <= west && this.north >= north && this.east >= east

    /** nearby.json, in the iPhone's JSON. */
    fun toJson(): JsonObject = buildJsonObject {
        put("south", Codec.number(south))
        put("west", Codec.number(west))
        put("north", Codec.number(north))
        put("east", Codec.number(east))
        put("fetchedAt", Codec.number(fetchedAt.sinceReference))
        put("places", JsonArray(places.map { place ->
            buildJsonObject {
                put("id", place.id)
                put("name", place.name)
                put("detail", place.detail)
                put("kind", place.kind)
                put("boundary", Codec.boundary(place.boundary))
                put("area", Codec.number(place.area))
                place.osmId?.let { put("osmId", it) }
            }
        }))
    }

    companion object {
        fun from(e: JsonElement): NearbyPlaces {
            val o = e as JsonObject
            fun JsonObject.double(key: String) = (this[key] as JsonPrimitive).doubleOrNull ?: throw Codec.Invalid(key)
            fun JsonObject.string(key: String) = (this[key] as JsonPrimitive).takeIf { it.isString }?.content ?: throw Codec.Invalid(key)
            return NearbyPlaces(
                south = o.double("south"), west = o.double("west"), north = o.double("north"), east = o.double("east"),
                fetchedAt = SwiftDate(o.double("fetchedAt")),
                places = (o["places"] as JsonArray).map {
                    val p = it as JsonObject
                    PlaceResult(
                        id = (p["id"] as JsonPrimitive).longOrNull ?: throw Codec.Invalid("id"),
                        name = p.string("name"),
                        detail = p.string("detail"),
                        kind = p.string("kind"),
                        boundary = Codec.boundary(p["boundary"] ?: throw Codec.Invalid("boundary")),
                        area = p.double("area"),
                        osmId = (p["osmId"] as? JsonPrimitive)?.longOrNull,
                    )
                },
            )
        }
    }
}

class OSMException(status: Int) : IOException("OpenStreetMap returned an error ($status).")

/**
 * The public OpenStreetMap services (OSMClient.swift): Nominatim for place boundaries,
 * Overpass for the streets and paths inside them and the suburbs nearby.
 */
class OSMClient(private val http: Http = Http.Default) {
    /**
     * Places matching the query that have a proper boundary. Nominatim asks for
     * no search-as-you-type, so only call this when you search or pick a suggestion.
     */
    suspend fun searchPlaces(query: String): List<PlaceResult> {
        val url = "https://nominatim.openstreetmap.org/search?" + form(
            "q" to query, "format" to "jsonv2", "polygon_geojson" to "1", "polygon_threshold" to "0.0001", "limit" to "10",
        )
        val items = get(url) as? JsonArray ?: return emptyList()
        return items.mapNotNull { (it as? JsonObject)?.let(::place) }
    }

    /** Lines for every street and path you could walk along inside the box. */
    suspend fun walkableWays(south: Double, west: Double, north: Double, east: Double): List<OSMWay> {
        val excluded = WalkableRule.EXCLUDED_HIGHWAYS.sorted().joinToString("|")
        // `out geom` brings every tag, which WalkableRule needs (sidewalk, foot, maxspeed).
        val query = "[out:json][timeout:120];\n" +
            "way[\"highway\"][\"highway\"!~\"^($excluded)$\"][\"access\"!~\"^(private|no)$\"][\"foot\"!~\"^(private|no)$\"]" +
            "($south,$west,$north,$east);\nout geom;"
        val elements = (overpass(query) as? JsonObject)?.get("elements") as? JsonArray ?: return emptyList()
        return elements.mapNotNull { element ->
            val o = element as? JsonObject ?: return@mapNotNull null
            val geometry = o["geometry"] as? JsonArray ?: return@mapNotNull null
            val tags = (o["tags"] as? JsonObject)
                ?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.contentOrNull?.let { k to it } }
                ?.toMap().orEmpty()
            if (!WalkableRule.isWalkable(tags)) return@mapNotNull null
            OSMWay(tags, geometry.mapNotNull { point ->
                val p = point as? JsonObject ?: return@mapNotNull null
                val lat = (p["lat"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                val lon = (p["lon"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                Coordinate(lat, lon)
            })
        }
    }

    /**
     * Suburbs and localities with a boundary in the box. In Australia they're
     * admin_level 9 (WA) or 10 (most other states). Overpass finds which ones, then
     * Nominatim hands over their outlines in the same shape a search does.
     */
    suspend fun placesNear(south: Double, west: Double, north: Double, east: Double): List<PlaceResult> {
        val query = "[out:json][timeout:60];\n" +
            "relation[\"boundary\"=\"administrative\"][\"admin_level\"~\"^(9|10)$\"]($south,$west,$north,$east);\nout ids;"
        // Overpass can be slow or down, so don't wait long: there's a fallback.
        val elements = (overpass(query, timeout = 45) as? JsonObject)?.get("elements") as? JsonArray ?: return emptyList()
        return lookup(elements.mapNotNull { ((it as? JsonObject)?.get("id") as? JsonPrimitive)?.longOrNull })
    }

    /**
     * The fallback for when Overpass is down: ask Nominatim which suburb each of
     * these points is in, one a second as it asks, then fetch their outlines.
     */
    suspend fun placesAt(points: List<Coordinate>): List<PlaceResult> {
        val ids = ArrayList<Long>()
        for ((n, point) in points.withIndex()) {
            if (n > 0) delay(1100)
            val url = "https://nominatim.openstreetmap.org/reverse?" + form(
                "lat" to point.lat.toString(), "lon" to point.lon.toString(),
                // Suburb level. Any closer and it can answer with the suburb's name pin rather than its boundary.
                "zoom" to "12", "format" to "jsonv2",
            )
            val item = get(url, english = false) as? JsonObject ?: continue
            if ((item["osm_type"] as? JsonPrimitive)?.contentOrNull != "relation") continue
            val id = (item["osm_id"] as? JsonPrimitive)?.longOrNull ?: continue
            if (id !in ids) ids.add(id)
        }
        delay(1100)
        return lookup(ids)
    }

    /** Outlines for these OSM boundary relations, from Nominatim. */
    private suspend fun lookup(ids: List<Long>): List<PlaceResult> {
        val places = ArrayList<PlaceResult>()
        // Nominatim looks up at most 50 at a time, and asks for one request a second.
        for ((n, chunk) in ids.chunked(50).withIndex()) {
            if (n > 0) delay(1000)
            val url = "https://nominatim.openstreetmap.org/lookup?" + form(
                "osm_ids" to chunk.joinToString(",") { "R$it" },
                "format" to "jsonv2", "polygon_geojson" to "1", "polygon_threshold" to "0.0001",
            )
            val items = get(url) as? JsonArray ?: continue
            places += items.mapNotNull { (it as? JsonObject)?.let(::place) }
        }
        return places
    }

    private suspend fun get(url: String, english: Boolean = true): JsonElement? {
        val headers = HashMap<String, String>()
        headers["User-Agent"] = USER_AGENT
        if (english) headers["Accept-Language"] = "en"
        val response = withContext(Dispatchers.IO) { http.send(url, null, headers, 60) }
        if (response.status !in 200..299) throw OSMException(response.status)
        return withContext(Dispatchers.Default) { Json.parseToJsonElement(response.body.decodeToString()) }
    }

    /** Runs an Overpass query, trying each server in turn. */
    private suspend fun overpass(query: String, timeout: Int = 150): JsonElement? {
        val body = "data=" + URLEncoder.encode(query, "UTF-8")
        var lastError: Exception = OSMException(0)
        for (endpoint in OVERPASS) {
            try {
                val response = withContext(Dispatchers.IO) {
                    http.send(
                        endpoint, body.toByteArray(),
                        mapOf("User-Agent" to USER_AGENT, "Content-Type" to "application/x-www-form-urlencoded"),
                        timeout,
                    )
                }
                if (response.status !in 200..299) throw OSMException(response.status)
                return withContext(Dispatchers.Default) { Json.parseToJsonElement(response.body.decodeToString()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError
    }

    companion object {
        const val USER_AGENT = "Walkies/0.1 (personal Android app)"

        val OVERPASS = listOf(
            "https://overpass-api.de/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        )

        private fun form(vararg pairs: Pair<String, String>) =
            pairs.joinToString("&") { (k, v) -> URLEncoder.encode(k, "UTF-8") + "=" + URLEncoder.encode(v, "UTF-8") }

        /** One Nominatim result, if it has an outline. */
        fun place(item: JsonObject): PlaceResult? {
            val id = (item["place_id"] as? JsonPrimitive)?.longOrNull ?: return null
            val geojson = item["geojson"] as? JsonObject ?: return null
            val type = (geojson["type"] as? JsonPrimitive)?.contentOrNull ?: return null
            val coordinates = geojson["coordinates"] ?: return null
            val polygons = when (type) {
                "Polygon" -> listOfNotNull(polygon(coordinates))
                "MultiPolygon" -> (coordinates as? JsonArray)?.mapNotNull(::polygon).orEmpty()
                else -> return null
            }
            if (polygons.isEmpty()) return null

            val parts = ((item["display_name"] as? JsonPrimitive)?.contentOrNull ?: "").split(", ").toMutableList()
            val name = (item["name"] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }
                ?: parts.firstOrNull()?.takeIf { it.isNotEmpty() } ?: "Somewhere"
            if (parts.firstOrNull() == name) parts.removeAt(0)

            val boundary = Boundary(polygons)
            val area = BoundaryShape(boundary, LocalProjection(boundary.centre)).area
            val kind = (item["addresstype"] as? JsonPrimitive)?.contentOrNull
                ?: (item["type"] as? JsonPrimitive)?.contentOrNull ?: "place"
            val relation = (item["osm_type"] as? JsonPrimitive)?.contentOrNull == "relation"
            return PlaceResult(
                id = id, name = name, detail = parts.joinToString(", "), kind = kind, boundary = boundary, area = area,
                osmId = if (relation) (item["osm_id"] as? JsonPrimitive)?.longOrNull else null,
            )
        }

        /** GeoJSON polygon: rings of [lon, lat], the first is the outline and the rest are holes. */
        private fun polygon(any: JsonElement): GeoPolygon? {
            val rings = (any as? JsonArray ?: return null).map { ring ->
                (ring as? JsonArray ?: return null).mapNotNull { point ->
                    val pair = point as? JsonArray ?: return@mapNotNull null
                    if (pair.size < 2) return@mapNotNull null
                    val lon = (pair[0] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                    val lat = (pair[1] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                    Coordinate(lat, lon)
                }
            }
            val outer = rings.firstOrNull() ?: return null
            return GeoPolygon(outer, rings.drop(1))
        }
    }
}
