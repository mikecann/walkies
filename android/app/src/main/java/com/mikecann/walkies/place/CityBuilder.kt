package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import kotlin.math.ceil
import kotlin.math.max

object CityBuilder {
    /** Metres between samples along a line (CoverageTracer.spacing). */
    const val SPACING = 10.0

    /**
     * Lays the world grid over the place and keeps the tiles with a street or path
     * through them. Walk replay comes with stage 2.
     */
    fun build(name: String, detail: String, osmId: Long?, boundary: Boundary, ways: List<OSMWay>): City {
        val grid = HexGrid
        val shape = BoundaryShape(boundary, grid.projection)
        val inside = City.hexes(shape, grid)

        var tiles: Set<Hex> = HashSet<Hex>().also { tiles ->
            // A driveway leads onto someone's property, so it doesn't make a tile count.
            for (way in ways) {
                if (way.tags["service"] == "driveway") continue
                for (point in samples(way.points)) {
                    val h = grid.hex(containing = point)
                    if (h in inside) tiles.add(h)
                }
            }
        }
        // Somewhere with no mapped paths at all: fall back to every tile.
        if (tiles.isEmpty()) tiles = inside

        return City(name = name, detail = detail, osmId = osmId, boundary = boundary, tiles = tiles, visited = emptySet(), roads = roadLines(ways))
    }

    /**
     * The streets and paths worth hinting at under the clouds. Everything walkable
     * still counts for tiles; this just drops the clutter (sidewalks drawn alongside
     * roads, crossings, driveways and car park aisles).
     */
    fun roadLines(ways: List<OSMWay>): List<RoadLine> {
        val pathTypes = setOf("footway", "path", "cycleway", "steps", "pedestrian", "track", "bridleway")
        return ways.mapNotNull { way ->
            if ((way.tags["footway"] ?: "") in setOf("sidewalk", "crossing", "traffic_island")) return@mapNotNull null
            if ((way.tags["service"] ?: "") in setOf("driveway", "parking_aisle", "drive-through")) return@mapNotNull null
            if (way.points.size <= 1) return@mapNotNull null
            val kind = if ((way.tags["highway"] ?: "") in pathTypes) RoadLine.Kind.Path else RoadLine.Kind.Road
            RoadLine(kind, way.points)
        }
    }

    /** Points every few metres along a line, so short tiles between nodes aren't skipped. */
    fun samples(line: List<Coordinate>): List<Coordinate> {
        var prev = line.firstOrNull() ?: return emptyList()
        val out = arrayListOf(prev)
        for (next in line.drop(1)) {
            val n = max(1, ceil(prev.distance(next) / SPACING).toInt())
            for (i in 1..n) out.add(prev.lerp(next, i.toDouble() / n))
            prev = next
        }
        return out
    }
}
