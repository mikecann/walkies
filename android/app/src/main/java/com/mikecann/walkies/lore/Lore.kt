package com.mikecann.walkies.lore

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.map.SplitMix64
import com.mikecann.walkies.place.City
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.File
import java.util.UUID

/**
 * A bit of local history or a story about a place, found by walking to it.
 * Each one is a sticker for the sticker book. LoreEntry in Lore.swift.
 */
data class LoreEntry(
    val id: String,
    val title: String,
    val body: String,
    /** history, first-nations, nature, the-sea, odd-records or modern-life. */
    val category: String,
    /** Where the story happened, when it's about one spot. */
    val place: Place? = null,
    /** What the sticker shows, for making the art. */
    val sticker: String = "",
    val sources: List<String> = emptyList(),
    /**
     * The suburb the story belongs to, as OpenStreetMap names it. The first batch
     * (geographe.json) doesn't say; its pins decide.
     */
    val suburb: String? = null,
    /** One or two photos from Wikimedia Commons, shown under the story. */
    val photos: List<Photo>? = null,
) {
    data class Place(val name: String, val lat: Double, val lon: Double) {
        val coordinate get() = Coordinate(lat, lon)
    }

    /** A freely licensed photo, bundled as an asset, with the credit its licence asks for. */
    data class Photo(
        val asset: String,
        val caption: String,
        /** Who took it and the licence, e.g. "Jane Smith · CC BY-SA 4.0". */
        val credit: String,
        /** Its page on Commons. */
        val source: String,
    )

    /** The same JSON as the iPhone's Codable LoreEntry, for server-lore.json. */
    fun toJson(): JsonObject = buildJsonObject {
        put("id", id)
        put("title", title)
        put("body", body)
        put("category", category)
        place?.let { p ->
            put("place", buildJsonObject {
                put("name", p.name)
                put("lat", p.lat)
                put("lon", p.lon)
            })
        }
        put("sticker", sticker)
        put("sources", JsonArray(sources.map(::JsonPrimitive)))
        suburb?.let { put("suburb", it) }
        photos?.let { list ->
            put("photos", JsonArray(list.map { photo ->
                buildJsonObject {
                    put("asset", photo.asset)
                    put("caption", photo.caption)
                    put("credit", photo.credit)
                    put("source", photo.source)
                }
            }))
        }
    }

    companion object {
        fun parse(json: String): List<LoreEntry> = Json.parseToJsonElement(json).jsonArray.map { from(it.jsonObject) }

        fun from(o: JsonObject): LoreEntry {
            fun string(key: String) = o[key]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull
            val place = o["place"]?.takeIf { it !is JsonNull }?.jsonObject?.let { p ->
                Place(
                    p["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    p["lat"]!!.jsonPrimitive.doubleOrNull!!,
                    p["lon"]!!.jsonPrimitive.doubleOrNull!!,
                )
            }
            val photos = (o["photos"] as? JsonArray)?.map { element: JsonElement ->
                val p = element.jsonObject
                fun field(key: String) = p[key]?.jsonPrimitive?.contentOrNull.orEmpty()
                Photo(field("asset"), field("caption"), field("credit"), field("source"))
            }
            return LoreEntry(
                id = string("id")!!,
                title = string("title").orEmpty(),
                body = string("body").orEmpty(),
                category = string("category").orEmpty(),
                place = place,
                sticker = string("sticker").orEmpty(),
                sources = (o["sources"] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty(),
                suburb = string("suburb"),
                photos = photos,
            )
        }
    }
}

/**
 * The lore the app knows about: what ships with it (the Busselton area so far), and
 * what the server has written for your other places ([ServerLore]), which the app
 * hands over with [useServer]. LoreLibrary in Lore.swift.
 * On the phone the app points [reader] at its assets before anything reads [bundled];
 * on the JVM in tests it reads the iPhone's Walkies/Lore folder directly.
 */
object LoreLibrary {
    val files = listOf("geographe", "busselton-area")

    /** Reads one lore file's JSON by name, or null if it isn't there. */
    var reader: (String) -> String? = { name ->
        val folder = System.getProperty("walkies.lore")
        folder?.let { File(it, "$name.json").takeIf(File::exists)?.readText() }
    }

    /** The secrets that ship with the app. */
    val bundled: List<LoreEntry> by lazy {
        files.flatMap { name -> runCatching { reader(name)?.let(LoreEntry::parse) }.getOrNull().orEmpty() }
    }

    /**
     * The OpenStreetMap relations the bundled secrets cover, from bundled-places.json
     * (the server's `bundledOsmIds`, which a server test keeps it matching). These
     * places never ask the server for secrets.
     */
    val bundledOsmIds: Set<Long> by lazy {
        runCatching {
            reader("bundled-places")?.let { json ->
                Json.parseToJsonElement(json).jsonObject["places"]!!.jsonArray
                    .mapTo(HashSet()) { it.jsonObject["osmId"]!!.jsonPrimitive.long }
            }
        }.getOrNull().orEmpty()
    }

    private val byId: Map<String, LoreEntry> by lazy {
        val out = LinkedHashMap<String, LoreEntry>()
        for (entry in bundled) out.putIfAbsent(entry.id, entry)
        out
    }

    /** The server's secrets, as last handed over. Swapped whole, as the views and the notifier read it from other threads. */
    private class Server(
        val all: List<LoreEntry> = emptyList(),
        val byId: Map<String, LoreEntry> = emptyMap(),
        val stickers: File? = null,
        val revision: Int = 0,
    )

    @Volatile
    private var server = Server()

    /** Every secret: the bundled ones, then the server's. */
    val all: List<LoreEntry> get() = bundled + server.all

    fun entry(id: String): LoreEntry? = byId[id] ?: server.byId[id]

    fun bundledEntry(id: String): LoreEntry? = byId[id]

    /** Goes up whenever the server's secrets or their art change, so cached images go too. */
    val serverRevision: Int get() = server.revision

    /** Takes the server's secrets for the views and notifications, with the folder their sticker art is saved in. */
    @Synchronized
    fun useServer(lore: ServerLore, stickers: File) {
        val entries = lore.all.filter { it.id !in byId }
        server = Server(entries, entries.associateBy { it.id }, stickers, server.revision + 1)
    }

    /** A server secret's sticker art, if it's been downloaded. Bundled ones are assets. */
    fun serverSticker(id: String): File? {
        val folder = server.stickers ?: return null
        return ServerLore.stickerFile(id, folder).takeIf(File::exists)
    }

    /**
     * Which secrets each place gets. A story about a spot belongs to the place that
     * spot is in, so it's found where it happened, and waits there until you add
     * that place. One about a whole suburb goes to that suburb, scattered over its
     * streets. The few from the first batch that aren't about anywhere in particular
     * go to the first Busselton-area place you added. The server's secrets ([server],
     * by OpenStreetMap relation) go to the place with that relation, pins and all.
     */
    fun assign(
        entries: List<LoreEntry>,
        cities: List<City>,
        server: Map<Long, List<LoreEntry>> = emptyMap(),
        contains: (City, Coordinate) -> Boolean,
    ): Map<UUID, List<LoreEntry>> {
        val home = cities.firstOrNull { "${it.name}, ${it.detail}".contains("Busselton") }
        val out = LinkedHashMap<UUID, MutableList<LoreEntry>>()
        for (entry in entries) {
            val place = entry.place
            val suburb = entry.suburb
            val owner = when {
                place != null -> cities.firstOrNull { contains(it, place.coordinate) }
                suburb != null -> cities.firstOrNull { it.name.equals(suburb, ignoreCase = true) }
                else -> home
            } ?: continue
            out.getOrPut(owner.id) { ArrayList() }.add(entry)
        }
        // By relation, not by name: two suburbs can share a name, and the server's
        // pins have already been moved inside the one it researched.
        for ((osmId, list) in server.toSortedMap()) {
            val owner = cities.firstOrNull { it.osmId == osmId } ?: continue
            out.getOrPut(owner.id) { ArrayList() }.addAll(list)
        }
        return out
    }
}

/**
 * Hides each sticker under a tile. Stories about a spot in the suburb go under the
 * nearest street tile to it; the rest are spread out, as far apart as possible, on
 * tiles you haven't walked yet. Worked out once and saved, so stickers never move.
 * Leaves alone any tiles in [avoiding], which already have a sticker.
 * City.placeStickers in Lore.swift, and must pick exactly the same tiles.
 */
fun City.placeStickers(entries: List<LoreEntry>, avoiding: Set<Hex> = emptySet()): Map<String, Hex> {
    val shape = shape()
    val streets = tiles.sortedWith(compareBy<Hex>({ it.q }, { it.r }))
    if (streets.isEmpty()) return emptyMap()
    val placed = LinkedHashMap<String, Hex>()
    val taken = HashSet(avoiding)
    val ordered = entries.sortedBy { it.id }

    for (entry in ordered) {
        val place = entry.place ?: continue
        val spot = grid.projection.project(place.coordinate)
        if (!shape.contains(spot)) continue
        val nearest = streets
            .filter { it !in taken }
            .minByOrNull { grid.centre(it).distance(spot) }
        if (nearest != null && grid.centre(nearest).distance(spot) < 300) {
            placed[entry.id] = nearest
            taken.add(nearest)
        }
    }

    val open = streets.filter { it !in visited }
    if (open.isEmpty()) return placed
    for (entry in ordered) {
        if (entry.id in placed) continue
        // Try a handful of tiles, picked the same way every time for this entry,
        // and keep the one furthest from every other sticker.
        val rng = SplitMix64(stableHash(entry.id))
        var best: Hex? = null
        var bestGap = -1.0
        repeat(40) {
            val candidate = open[java.lang.Long.remainderUnsigned(rng.next(), open.size.toLong()).toInt()]
            if (candidate in taken) return@repeat
            val centre = grid.centre(candidate)
            val gap = taken.minOfOrNull { centre.distance(grid.centre(it)) } ?: Double.POSITIVE_INFINITY
            if (gap > bestGap) {
                best = candidate
                bestGap = gap
            }
        }
        best?.let {
            placed[entry.id] = it
            taken.add(it)
        }
    }
    return placed
}

/** FNV-1a, as City.stableHash in Lore.swift. The bits of Swift's UInt64, in a Long. */
fun stableHash(text: String): Long {
    var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
    for (byte in text.toByteArray(Charsets.UTF_8)) {
        hash = (hash xor (byte.toLong() and 0xff)) * 0x100000001b3L
    }
    return hash
}
