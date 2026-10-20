package com.mikecann.walkies.lore

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.place.City

/**
 * The book works from the whole library, even for places you haven't added yet.
 * Distances belong to areas, never to individual mystery stickers. SecretsBook.swift.
 */
object SecretsBook {
    enum class Sort(val title: String) {
        Nearest("Nearest first"), Alphabetical("A to Z"), MostFound("Most found");

        /** The iPhone's raw values, for the saved setting. */
        val key get() = when (this) {
            Nearest -> "nearest"
            Alphabetical -> "alphabetical"
            MostFound -> "mostFound"
        }

        companion object {
            fun from(key: String?) = entries.firstOrNull { it.key == key } ?: Nearest
        }
    }

    enum class Filter(val title: String) {
        All("All"), Found("Found"), NotFound("Not found yet");

        val key get() = when (this) {
            All -> "all"
            Found -> "found"
            NotFound -> "notFound"
        }

        companion object {
            fun from(key: String?) = entries.firstOrNull { it.key == key } ?: All
        }
    }

    data class Area(
        val name: String,
        /** Only entries matching the filter. Counts and distance still cover the whole area. */
        val entries: List<LoreEntry>,
        val found: Int,
        val total: Int,
        val distance: Double?,
        val isAdded: Boolean,
    ) {
        val id get() = name
        val progress: Double get() = if (total == 0) 0.0 else found.toDouble() / total
    }

    const val AROUND_BUSSELTON = "Around Busselton"

    private fun areaName(entry: LoreEntry) = entry.suburb ?: AROUND_BUSSELTON

    /** Use the full library so a filter hiding your area doesn't change its expansion. */
    fun currentAreaName(entries: List<LoreEntry>, selectedCityName: String?): String? {
        selectedCityName ?: return null
        return entries.asSequence().map(::areaName).firstOrNull { it.equals(selectedCityName, ignoreCase = true) }
    }

    fun sections(
        entries: List<LoreEntry>,
        found: Map<String, SwiftDate>,
        location: Coordinate?,
        places: List<City>,
        selectedCity: City? = null,
        sort: Sort = Sort.Nearest,
        filter: Filter = Filter.All,
    ): List<Area> {
        val origin = location ?: selectedCity?.boundary?.centre
        val grouped = LinkedHashMap<String, MutableList<LoreEntry>>()
        for (entry in entries) grouped.getOrPut(areaName(entry)) { ArrayList() }.add(entry)
        val areas = grouped.mapNotNull { (name, all) ->
            val visible = all.filter { entry ->
                when (filter) {
                    Filter.All -> true
                    Filter.Found -> found[entry.id] != null
                    Filter.NotFound -> found[entry.id] == null
                }
            }
            if (visible.isEmpty()) return@mapNotNull null
            val distance = origin?.let { o -> all.mapNotNull { it.place?.coordinate?.distance(o) }.minOrNull() }
            Area(
                name = name,
                // Keep the newest finds first, as in the original book.
                entries = visible.sortedWith { a, b ->
                    val x = found[a.id]
                    val y = found[b.id]
                    when {
                        x != null && y != null && x != y -> y.compareTo(x)
                        x != null && y == null -> -1
                        x == null && y != null -> 1
                        a.title == b.title -> a.id.compareTo(b.id)
                        else -> a.title.compareTo(b.title)
                    }
                },
                found = all.count { found[it.id] != null },
                total = all.size,
                distance = distance,
                isAdded = places.any { it.name.equals(name, ignoreCase = true) },
            )
        }
        return areas.sortedWith { a, b ->
            val decided = when (sort) {
                // With no fix or selected place, every distance is nil and names decide.
                Sort.Nearest -> when {
                    a.distance != null && b.distance != null && a.distance != b.distance -> a.distance.compareTo(b.distance)
                    a.distance != null && b.distance == null -> -1
                    a.distance == null && b.distance != null -> 1
                    else -> 0
                }
                Sort.MostFound -> b.found.compareTo(a.found)
                Sort.Alphabetical -> 0
            }
            if (decided != 0) decided else compareNames(a.name, b.name)
        }
    }

    /** Like Foundation's localizedStandardCompare for plain names: case doesn't matter, then it does. */
    private fun compareNames(a: String, b: String): Int {
        val order = String.CASE_INSENSITIVE_ORDER.compare(a, b)
        return if (order != 0) order else a.compareTo(b)
    }
}
