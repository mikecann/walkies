package com.mikecann.walkies.lore

import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.place.City
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import java.net.URLEncoder

/**
 * Secrets the server has written for your places that have no bundled ones
 * (shared/lore-api.md): what `lore:forPlace` last said about each, saved in
 * server-lore.json with their sticker art in server-stickers/, so they work offline.
 * The app asks again now and then ([due]), and a new version replaces the last lot.
 * ServerLore in ServerLore.swift, and the same JSON.
 */
data class ServerLore(
    val places: List<Place> = emptyList(),
    /** Secrets the server has taken down since you found them, so they stay in your book. */
    val kept: List<LoreEntry> = emptyList(),
    /** Where each saved sticker came from, by secret id, so art is only downloaded again when it's changed. */
    val savedStickers: Map<String, String> = emptyMap(),
) {
    /** Where the server's got to with a place. */
    enum class Status(val raw: String) {
        /** The app ships this place's secrets, so it never asks again. */
        Bundled("bundled"),
        /** Nobody's walked there since the server started researching. */
        NotStarted("none"),
        /** Waiting for a free slot, or for a spending cap to reset. */
        Queued("queued"),
        /** A run's going. It takes 5 to 15 minutes. */
        Researching("researching"),
        Ready("ready"),
        /** Done, but there wasn't much to find. */
        Quiet("quiet"),
        /** The run broke. The server has another go after a day. */
        Failed("failed");

        /** Still being looked into, so the map says so. */
        val isLooking: Boolean get() = this == Queued || this == Researching

        companion object {
            /** A status from a newer server that this version doesn't know is like "none". */
            fun of(raw: String?): Status = entries.firstOrNull { it.raw == raw } ?: NotStarted
        }
    }

    /** What `lore:forPlace` answers. */
    data class Answer(val status: Status, val version: Int, val entries: List<Entry>) {
        companion object {
            fun from(e: JsonElement): Answer {
                val o = e as? JsonObject ?: throw Codec.Invalid("forPlace")
                return Answer(
                    status = Status.of((o["status"] as? JsonPrimitive)?.contentOrNull),
                    // Convex sends every number as a double ("8.0"), so read it as one.
                    version = (o["version"] as? JsonPrimitive)?.doubleOrNull?.toInt() ?: throw Codec.Invalid("version"),
                    entries = (o["entries"] as? JsonArray)?.map(Entry::from).orEmpty(),
                )
            }
        }
    }

    /**
     * One secret as the server sends it: the same JSON as a bundled LoreEntry, plus
     * where its sticker art is (`stickerUrl`, null if the drawing failed).
     */
    data class Entry(val entry: LoreEntry, val stickerUrl: String? = null) {
        companion object {
            fun from(e: JsonElement): Entry {
                val o = e as? JsonObject ?: throw Codec.Invalid("entry")
                return Entry(LoreEntry.from(o), o["stickerUrl"]?.takeIf { it !is JsonNull }?.let { (it as JsonPrimitive).contentOrNull })
            }
        }
    }

    /** The last answer for one place. */
    data class Place(
        val osmId: Long,
        val status: Status,
        val version: Int,
        val entries: List<LoreEntry>,
        /** Where each secret's art is on the server, by id. Missing when it hasn't got any. */
        val stickerUrls: Map<String, String> = emptyMap(),
        /** When the server was last asked about it, whether it answered or not. */
        val askedAt: SwiftDate,
    )

    fun place(osmId: Long): Place? = places.firstOrNull { it.osmId == osmId }

    /** Whether the server's answered about this place yet, rather than not been asked or not answered. */
    fun hasAnswered(osmId: Long): Boolean = (place(osmId)?.version ?: -1) >= 0

    /** The live secrets by OpenStreetMap relation, for LoreLibrary.assign. */
    val byPlace: Map<Long, List<LoreEntry>> get() = places.associate { it.osmId to it.entries }

    /** Every secret here: each place's, then the kept ones. */
    val all: List<LoreEntry> get() = (places.flatMap { it.entries } + kept).distinctBy { it.id }

    fun entry(id: String): LoreEntry? = places.firstNotNullOfOrNull { p -> p.entries.firstOrNull { it.id == id } } ?: kept.firstOrNull { it.id == id }

    /**
     * Which of your places could have secrets from the server: ones with an
     * OpenStreetMap relation that the app has no bundled secrets for, and that the
     * server hasn't said it has.
     */
    fun askable(cities: List<City>): List<Long> =
        cities.mapNotNull { it.osmId }.distinct().filter { it !in LoreLibrary.bundledOsmIds && place(it)?.status != Status.Bundled }

    /** Of [osmIds], the ones due another ask at [now]. */
    fun due(osmIds: List<Long>, now: SwiftDate): List<Long> = osmIds.filter { osmId ->
        val place = place(osmId) ?: return@filter true
        now.sinceReference - place.askedAt.sinceReference >= wait(place.status)
    }

    /** What taking in an answer changed. */
    data class Change(
        /** Secrets that weren't here before, for the note on the map. */
        val arrived: List<LoreEntry> = emptyList(),
        /** The place has just turned out to have nothing much to find. */
        val quiet: Boolean = false,
        /** Sticker art to download, by secret id. */
        val stickers: Map<String, String> = emptyMap(),
    )

    /**
     * Takes in what the server said about a place. The same version as last time
     * changes nothing but the status. A new one replaces the place's secrets, since
     * one can be taken down later; one taken down after you'd found it (in [found])
     * is kept, so it stays in your book.
     */
    fun taking(answer: Answer, osmId: Long, now: SwiftDate, found: Map<String, SwiftDate>): Pair<ServerLore, Change> {
        val old = place(osmId)
        var place = (old ?: Place(osmId, answer.status, -1, emptyList(), askedAt = now)).copy(status = answer.status, askedAt = now)
        val quiet = answer.status == Status.Quiet && answer.entries.isEmpty() && old?.status != Status.Quiet
        var arrived = emptyList<LoreEntry>()
        var kept = this.kept
        if (answer.version != place.version) {
            val entries = answer.entries.map { it.entry }
            val live = entries.mapTo(HashSet()) { it.id }
            val had = place.entries.mapTo(HashSet()) { it.id }
            arrived = entries.filter { it.id !in had }
            for (gone in place.entries) {
                if (gone.id !in live && found[gone.id] != null && kept.none { it.id == gone.id }) kept = kept + gone
            }
            // Back again (approved after being hidden, say): live, not kept.
            kept = kept.filter { it.id !in live }
            val urls = LinkedHashMap<String, String>()
            for (e in answer.entries) e.stickerUrl?.let { urls.putIfAbsent(e.entry.id, it) }
            place = place.copy(version = answer.version, entries = entries, stickerUrls = urls)
        }
        val places = if (old == null) this.places + place else this.places.map { if (it.osmId == osmId) place else it }
        // Also any that didn't download last time.
        val stickers = place.stickerUrls.filter { savedStickers[it.key] != it.value }
        return copy(places = places, kept = kept) to Change(arrived, quiet, stickers)
    }

    /** The server didn't answer, so wait the usual time before asking about it again. */
    fun asked(osmId: Long, now: SwiftDate): ServerLore =
        if (place(osmId) != null) copy(places = places.map { if (it.osmId == osmId) it.copy(askedAt = now) else it })
        else copy(places = places + Place(osmId, Status.NotStarted, -1, emptyList(), askedAt = now))

    /**
     * Forgets places that aren't yours any more (deleted, say), keeping any of their
     * secrets you'd found. Also returns the secrets whose saved art can go.
     */
    fun keepingOnly(osmIds: Set<Long>, found: Map<String, SwiftDate>): Pair<ServerLore, List<String>> {
        var kept = this.kept
        for (place in places) {
            if (place.osmId in osmIds) continue
            for (entry in place.entries) {
                if (found[entry.id] != null && kept.none { it.id == entry.id }) kept = kept + entry
            }
        }
        val trimmed = copy(places = places.filter { it.osmId in osmIds }, kept = kept)
        val wanted = trimmed.all.mapTo(HashSet()) { it.id }
        val unused = savedStickers.keys.filter { it !in wanted }.sorted()
        return trimmed.copy(savedStickers = savedStickers - unused.toSet()) to unused
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("places", JsonArray(places.map { place ->
            buildJsonObject {
                put("osmId", place.osmId)
                put("status", place.status.raw)
                put("version", place.version)
                put("entries", JsonArray(place.entries.map { it.toJson() }))
                put("stickerURLs", JsonObject(place.stickerUrls.mapValues { JsonPrimitive(it.value) }))
                put("askedAt", Codec.number(place.askedAt.sinceReference))
            }
        }))
        put("kept", JsonArray(kept.map { it.toJson() }))
        put("savedStickers", JsonObject(savedStickers.mapValues { JsonPrimitive(it.value) }))
    }

    companion object {
        /** How long after asking about a place to ask again, in seconds, by what it said. */
        fun wait(status: Status): Double = when (status) {
            // A run takes 5 to 15 minutes, so every couple of minutes while the app's open.
            Status.Queued, Status.Researching -> 110.0
            // A walk there can start a run, and sync asks again after each one.
            Status.NotStarted, Status.Failed -> 10 * 60.0
            // These only change when Mike approves or hides one.
            Status.Ready, Status.Quiet -> 60 * 60.0
            Status.Bundled -> Double.POSITIVE_INFINITY
        }

        /** Anything that won't read starts empty, and the server's asked again. */
        fun from(e: JsonElement): ServerLore {
            val o = e as JsonObject
            fun urls(element: JsonElement?) = (element as? JsonObject)?.mapValues { (it.value as JsonPrimitive).content }.orEmpty()
            return ServerLore(
                places = (o["places"] as? JsonArray)?.map { element ->
                    val p = element as? JsonObject ?: throw Codec.Invalid("places")
                    Place(
                        osmId = (p["osmId"] as? JsonPrimitive)?.longOrNull ?: throw Codec.Invalid("osmId"),
                        status = Status.of((p["status"] as? JsonPrimitive)?.contentOrNull),
                        version = (p["version"] as? JsonPrimitive)?.intOrNull ?: throw Codec.Invalid("version"),
                        entries = (p["entries"] as? JsonArray)?.map { LoreEntry.from(it as JsonObject) }.orEmpty(),
                        stickerUrls = urls(p["stickerURLs"]),
                        askedAt = SwiftDate((p["askedAt"] as? JsonPrimitive)?.doubleOrNull ?: throw Codec.Invalid("askedAt")),
                    )
                }.orEmpty(),
                kept = (o["kept"] as? JsonArray)?.map { LoreEntry.from(it as JsonObject) }.orEmpty(),
                savedStickers = urls(o["savedStickers"]),
            )
        }

        /**
         * A server secret's sticker file in [folder]. The id comes from the server, so
         * it's made safe as a file name first (as the iPhone does).
         */
        fun stickerFile(id: String, folder: File): File {
            val safe = id.map { c -> if (c.isLetterOrDigit() || c == '-' || c == '_') c.toString() else URLEncoder.encode(c.toString(), "UTF-8").replace("+", "%20") }
            return File(folder, safe.joinToString("") + ".png")
        }

        /** Whether downloaded art really is a PNG, rather than an error page. */
        fun isPng(data: ByteArray): Boolean =
            data.size >= 8 && byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A).withIndex().all { (i, b) -> data[i] == b }
    }
}
