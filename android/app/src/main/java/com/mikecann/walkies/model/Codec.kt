package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.place.Boundary
import com.mikecann.walkies.place.City
import com.mikecann.walkies.place.GeoPolygon
import com.mikecann.walkies.place.RoadLine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.math.BigDecimal
import java.util.UUID

/**
 * The save files, in exactly the JSON the iPhone's `JSONEncoder` writes, so the same
 * files (and the blobs sync uploads) work on both phones:
 *
 * - Every non-optional field is always written, since Swift's synthesised `Decodable`
 *   fails on a missing key even when the property has a default.
 * - Optionals are left out when null, like Swift's `encodeIfPresent`, and read whether
 *   they're missing or null.
 * - `Date`s are seconds since 2001 ([SwiftDate]). Track points and the ledger keep
 *   seconds since 1970 in plain doubles.
 * - Hexes are `[q, r]`, UUIDs uppercase strings.
 * - Dictionaries keyed by UUID (only in [SyncState]) are flat `[key, value, key, value]`
 *   arrays, which is how Swift encodes a dictionary whose key isn't a String or Int.
 * - Numbers are written the way Swift writes them (`1`, `812345678.25`), not Kotlin's
 *   `1.0` and `8.1234567825E8`, so the files diff cleanly against the iPhone's.
 */
object Codec {
    class Invalid(message: String) : Exception(message)

    /** A double as Swift's JSONEncoder writes it: whole numbers without a point, no exponent for everyday sizes. */
    fun number(d: Double): JsonPrimitive {
        if (!d.isFinite()) throw Invalid("Can't save $d")
        if (d == Math.rint(d) && kotlin.math.abs(d) < 9.007199254740992E15) return JsonPrimitive(d.toLong())
        return JsonPrimitive(BigDecimal(d.toString()).stripTrailingZeros())
    }

    private fun JsonObjectBuilder.put(key: String, value: Double) = put(key, number(value))

    fun parse(text: String): JsonElement = Json.parseToJsonElement(text)

    // Cities

    fun city(c: City): JsonObject = buildJsonObject {
        put("id", c.id.uuidString)
        put("name", c.name)
        put("detail", c.detail)
        c.osmId?.let { put("osmId", it) }
        c.gridVersion?.let { put("gridVersion", it) }
        put("boundary", boundary(c.boundary))
        put("tiles", hexes(c.tiles))
        put("visited", hexes(c.visited))
        c.roads?.let { put("roads", roads(it)) }
        c.stickers?.let { stickers -> put("stickers", JsonObject(stickers.mapValues { hex(it.value) })) }
        put("createdAt", c.createdAt.sinceReference)
        c.updatedAt?.let { put("updatedAt", it.sinceReference) }
        c.tileCredits?.let { credits ->
            put("tileCredits", JsonArray(credits.map { credit ->
                buildJsonObject {
                    put("id", credit.id.uuidString)
                    put("at", credit.at.sinceReference)
                    put("hexes", hexes(credit.hexes))
                }
            }))
        }
    }

    fun city(e: JsonElement): City {
        val o = e.obj()
        return City(
            id = o.uuid("id"),
            name = o.string("name"),
            detail = o.string("detail"),
            osmId = o.opt("osmId")?.long(),
            gridVersion = o.opt("gridVersion")?.int(),
            boundary = boundary(o.req("boundary")),
            tiles = hexes(o.req("tiles")),
            visited = hexes(o.req("visited")),
            roads = o.opt("roads")?.let(::roads),
            stickers = o.opt("stickers")?.obj()?.mapValuesTo(LinkedHashMap()) { hex(it.value) },
            createdAt = o.date("createdAt"),
            updatedAt = o.opt("updatedAt")?.let { SwiftDate(it.double()) },
            tileCredits = o.opt("tileCredits")?.arr()?.map {
                val credit = it.obj()
                City.TileCredit(credit.uuid("id"), credit.date("at"), hexes(credit.req("hexes")))
            },
        )
    }

    fun cities(list: List<City>) = JsonArray(list.map(::city))
    fun cities(e: JsonElement) = e.arr().map(::city)

    /** roads.json: each city's streets by its id. */
    fun roadsByCity(map: Map<String, List<RoadLine>>) = JsonObject(map.mapValues { roads(it.value) })
    fun roadsByCity(e: JsonElement): Map<String, List<RoadLine>> = e.obj().mapValuesTo(LinkedHashMap()) { roads(it.value) }

    fun boundary(b: Boundary) = buildJsonObject {
        put("polygons", JsonArray(b.polygons.map { polygon ->
            buildJsonObject {
                put("outer", coordinates(polygon.outer))
                put("holes", JsonArray(polygon.holes.map(::coordinates)))
            }
        }))
    }

    fun boundary(e: JsonElement) = Boundary(e.obj().req("polygons").arr().map {
        val polygon = it.obj()
        GeoPolygon(coordinates(polygon.req("outer")), polygon.req("holes").arr().map(::coordinates))
    })

    fun roads(list: List<RoadLine>) = JsonArray(list.map { road ->
        buildJsonObject {
            put("kind", if (road.kind == RoadLine.Kind.Road) "road" else "path")
            put("points", coordinates(road.points))
        }
    })

    fun roads(e: JsonElement) = e.arr().map {
        val road = it.obj()
        val kind = when (val k = road.string("kind")) {
            "road" -> RoadLine.Kind.Road
            "path" -> RoadLine.Kind.Path
            else -> throw Invalid("Unknown road kind $k")
        }
        RoadLine(kind, coordinates(road.req("points")))
    }

    fun coordinate(c: Coordinate) = buildJsonObject {
        put("lat", c.lat)
        put("lon", c.lon)
    }

    fun coordinate(e: JsonElement) = e.obj().let { Coordinate(it.double("lat"), it.double("lon")) }
    fun coordinates(list: List<Coordinate>) = JsonArray(list.map(::coordinate))
    fun coordinates(e: JsonElement) = e.arr().map(::coordinate)

    fun hex(h: Hex) = buildJsonArray {
        add(JsonPrimitive(h.q))
        add(JsonPrimitive(h.r))
    }

    fun hex(e: JsonElement): Hex {
        val a = e.arr()
        if (a.size != 2) throw Invalid("A hex is [q, r]")
        return Hex(a[0].int32(), a[1].int32())
    }

    fun hexes(set: Collection<Hex>) = JsonArray(set.map(::hex))

    /** In the order they were saved, so a file read and written again comes out the same. */
    fun hexes(e: JsonElement): Set<Hex> = e.arr().mapTo(LinkedHashSet(), ::hex)

    // Walks

    fun trackPoint(p: TrackPoint) = buildJsonObject {
        put("lat", p.lat)
        put("lon", p.lon)
        put("time", p.time)
        put("accuracy", p.accuracy)
        p.speed?.let { put("speed", it) }
        p.wheels?.let { put("wheels", it) }
        p.still?.let { put("still", it) }
    }

    fun trackPoint(e: JsonElement): TrackPoint {
        val o = e.obj()
        return TrackPoint(
            lat = o.double("lat"),
            lon = o.double("lon"),
            time = o.double("time"),
            accuracy = o.double("accuracy"),
            speed = o.opt("speed")?.double(),
            wheels = o.opt("wheels")?.bool(),
            still = o.opt("still")?.bool(),
        )
    }

    fun walk(w: Walk): JsonObject = buildJsonObject {
        put("id", w.id.uuidString)
        put("startedAt", w.startedAt.sinceReference)
        w.endedAt?.let { put("endedAt", it.sinceReference) }
        put("points", JsonArray(w.points.map(::trackPoint)))
        put("distance", w.distance)
        w.gridVersion?.let { put("gridVersion", it) }
        put("newTiles", w.newTiles)
        w.newTilesByPlace?.let { counts -> put("newTilesByPlace", JsonObject(counts.mapValues { JsonPrimitive(it.value) })) }
        w.newTileHexesByPlace?.let { put("newTileHexesByPlace", hexesByPlace(it)) }
        w.addedTilesByPlace?.let { put("addedTilesByPlace", hexesByPlace(it)) }
        w.automatic?.let { put("automatic", it) }
    }

    fun walk(e: JsonElement): Walk {
        val o = e.obj()
        return Walk(
            id = o.uuid("id"),
            startedAt = o.date("startedAt"),
            endedAt = o.opt("endedAt")?.let { SwiftDate(it.double()) },
            points = o.req("points").arr().map(::trackPoint),
            distance = o.double("distance"),
            gridVersion = o.opt("gridVersion")?.int(),
            newTiles = o.req("newTiles").int(),
            newTilesByPlace = o.opt("newTilesByPlace")?.obj()?.mapValuesTo(LinkedHashMap()) { it.value.int() },
            newTileHexesByPlace = o.opt("newTileHexesByPlace")?.let(::hexesByPlace),
            addedTilesByPlace = o.opt("addedTilesByPlace")?.let(::hexesByPlace),
            automatic = o.opt("automatic")?.bool(),
        )
    }

    private fun hexesByPlace(map: Map<String, Set<Hex>>) = JsonObject(map.mapValues { hexes(it.value) })
    private fun hexesByPlace(e: JsonElement): Map<String, Set<Hex>> = e.obj().mapValuesTo(LinkedHashMap()) { hexes(it.value) }

    // Secrets: stickers.json, when each was found by lore id.

    fun stickers(map: Map<String, SwiftDate>) = JsonObject(map.mapValues { number(it.value.sinceReference) })
    fun stickers(e: JsonElement): Map<String, SwiftDate> = e.obj().mapValuesTo(LinkedHashMap()) { SwiftDate(it.value.double()) }

    // Progress

    fun ledger(l: Ledger) = buildJsonObject {
        put("purchases", JsonArray(l.purchases.map {
            buildJsonObject { put("id", it.id); put("item", it.item); put("cost", it.cost); put("at", it.at) }
        }))
        put("claims", JsonArray(l.claims.map {
            buildJsonObject { put("level", it.level); put("choice", it.choice) }
        }))
        put("spyglasses", JsonArray(l.spyglasses.map { glass ->
            buildJsonObject {
                put("id", glass.id)
                put("secretId", glass.secretId)
                put("centre", JsonArray(glass.centre.map(::number)))
                put("at", glass.at)
            }
        }))
        put("equipped", l.equipped.let { e ->
            buildJsonObject {
                put("marker", e.marker)
                put("trail", e.trail)
                put("clouds", e.clouds)
                put("cover", e.cover)
                put("celebration", e.celebration)
                put("updatedAt", e.updatedAt)
            }
        })
        l.offers?.let { offers ->
            put("offers", JsonArray(offers.map { offer ->
                buildJsonObject {
                    put("level", offer.level)
                    put("choices", JsonArray(offer.choices.map(::JsonPrimitive)))
                }
            }))
        }
    }

    fun ledger(e: JsonElement): Ledger {
        val o = e.obj()
        val equipped = o.req("equipped").obj()
        return Ledger(
            purchases = o.req("purchases").arr().map {
                val p = it.obj()
                Ledger.Purchase(p.string("id"), p.string("item"), p.req("cost").int(), p.double("at"))
            },
            claims = o.req("claims").arr().map {
                val c = it.obj()
                Ledger.Claim(c.req("level").int(), c.string("choice"))
            },
            spyglasses = o.req("spyglasses").arr().map {
                val s = it.obj()
                Ledger.Spyglass(s.string("id"), s.string("secretId"), s.req("centre").arr().map { c -> c.double() }, s.double("at"))
            },
            equipped = Ledger.Equipped(
                marker = equipped.string("marker"),
                trail = equipped.string("trail"),
                clouds = equipped.string("clouds"),
                cover = equipped.string("cover"),
                celebration = equipped.string("celebration"),
                updatedAt = equipped.double("updatedAt"),
            ),
            offers = o.opt("offers")?.arr()?.map {
                val offer = it.obj()
                Ledger.Offer(offer.req("level").int(), offer.req("choices").arr().map { c -> c.string() })
            },
        )
    }

    /**
     * JSON as Swift's JSONEncoder writes it with `.sortedKeys`: keys sorted at every
     * level, no spaces, and slashes escaped. Sync compares the ledger in this form
     * (`progressJSON` in Sync.swift), so it must match the iPhone's byte for byte.
     */
    fun sortedKeys(e: JsonElement): String = StringBuilder().also { write(e, it) }.toString()

    private fun write(e: JsonElement, out: StringBuilder) {
        when (e) {
            is JsonObject -> {
                out.append('{')
                // Swift compares String keys by Unicode scalars; for these ASCII keys that's plain ordering.
                for ((i, key) in e.keys.sorted().withIndex()) {
                    if (i > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    write(e.getValue(key), out)
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                for ((i, item) in e.withIndex()) {
                    if (i > 0) out.append(',')
                    write(item, out)
                }
                out.append(']')
            }
            is JsonNull -> out.append("null")
            is JsonPrimitive -> if (e.isString) writeString(e.content, out) else out.append(e.content)
        }
    }

    private fun writeString(s: String, out: StringBuilder) {
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '/' -> out.append("\\/")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') out.append(String.format("\\u%04x", c.code)) else out.append(c)
            }
        }
        out.append('"')
    }

    // Sync bookkeeping

    fun syncState(s: SyncState) = buildJsonObject {
        put("uploadedWalks", JsonArray(s.uploadedWalks.map { JsonPrimitive(it.uuidString) }))
        put("uploadedPlaces", buildJsonArray {
            for ((id, date) in s.uploadedPlaces) {
                add(JsonPrimitive(id.uuidString))
                add(number(date.sinceReference))
            }
        })
        put("uploadedSecrets", JsonArray(s.uploadedSecrets.map(::JsonPrimitive)))
        s.uploadedProgress?.let { put("uploadedProgress", it) }
        s.deletedPlaces?.let { ids -> put("deletedPlaces", JsonArray(ids.map { JsonPrimitive(it.uuidString) })) }
    }

    fun syncState(e: JsonElement): SyncState {
        val o = e.obj()
        val places = LinkedHashMap<UUID, SwiftDate>()
        when (val p = o.req("uploadedPlaces")) {
            is JsonArray -> {
                if (p.size % 2 != 0) throw Invalid("uploadedPlaces needs a value for every key")
                for (i in p.indices step 2) places[parseUuid(p[i].string())] = SwiftDate(p[i + 1].double())
            }
            // In case a later Swift keys UUID dictionaries by string.
            is JsonObject -> for ((k, v) in p) places[parseUuid(k)] = SwiftDate(v.double())
            else -> throw Invalid("uploadedPlaces")
        }
        return SyncState(
            uploadedWalks = o.req("uploadedWalks").arr().mapTo(LinkedHashSet()) { parseUuid(it.string()) },
            uploadedPlaces = places,
            uploadedSecrets = o.req("uploadedSecrets").arr().mapTo(LinkedHashSet()) { it.string() },
            uploadedProgress = o.opt("uploadedProgress")?.string(),
            deletedPlaces = o.opt("deletedPlaces")?.arr()?.mapTo(LinkedHashSet()) { parseUuid(it.string()) },
        )
    }

    // Reading helpers. Anything missing or the wrong type throws, as JSONDecoder does.

    private fun parseUuid(s: String): UUID {
        if (s.length != 36) throw Invalid("Not a UUID: $s")
        return try {
            UUID.fromString(s)
        } catch (e: IllegalArgumentException) {
            throw Invalid("Not a UUID: $s")
        }
    }

    private fun JsonElement.obj() = this as? JsonObject ?: throw Invalid("Expected an object")
    private fun JsonElement.arr() = this as? JsonArray ?: throw Invalid("Expected an array")
    private fun JsonElement.prim(): JsonPrimitive = (this as? JsonPrimitive)?.takeIf { it !is JsonNull } ?: throw Invalid("Expected a value")

    private fun JsonElement.string(): String = prim().let { if (it.isString) it.content else throw Invalid("Expected a string") }

    private fun JsonElement.double(): Double {
        val p = prim()
        if (p.isString) throw Invalid("Expected a number")
        return p.content.toDoubleOrNull() ?: throw Invalid("Expected a number, got ${p.content}")
    }

    private fun JsonElement.long(): Long {
        val p = prim()
        if (p.isString) throw Invalid("Expected a number")
        p.content.toLongOrNull()?.let { return it }
        val d = p.content.toDoubleOrNull() ?: throw Invalid("Expected a whole number, got ${p.content}")
        if (d != Math.rint(d) || d > Long.MAX_VALUE || d < Long.MIN_VALUE) throw Invalid("Expected a whole number, got ${p.content}")
        return d.toLong()
    }

    private fun JsonElement.int(): Int {
        val v = long()
        if (v > Int.MAX_VALUE || v < Int.MIN_VALUE) throw Invalid("Number out of range: $v")
        return v.toInt()
    }

    /** Hexes are Int32 in Swift. */
    private fun JsonElement.int32() = int()

    private fun JsonElement.bool(): Boolean {
        val p = prim()
        if (p.isString) throw Invalid("Expected true or false")
        return p.booleanOrNull ?: throw Invalid("Expected true or false")
    }

    private fun JsonObject.req(key: String): JsonElement = this[key]?.takeIf { it !is JsonNull } ?: throw Invalid("Missing $key")
    private fun JsonObject.opt(key: String): JsonElement? = this[key]?.takeIf { it !is JsonNull }
    private fun JsonObject.string(key: String) = req(key).string()
    private fun JsonObject.double(key: String) = req(key).double()
    private fun JsonObject.uuid(key: String): UUID = parseUuid(string(key))
    private fun JsonObject.date(key: String) = SwiftDate(double(key))
}
