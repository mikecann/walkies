package com.mikecann.walkies.place

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import com.mikecann.walkies.model.CoverageTracer
import com.mikecann.walkies.model.Walk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.util.logging.Logger
import kotlin.math.ceil
import kotlin.math.max

object CityBuilder {
    /** Metres between samples along a line (CoverageTracer.spacing). */
    const val SPACING = 10.0

    /** Square metres. Anything bigger is years of walking, so we suggest a suburb instead. */
    const val MAX_AREA = 400_000_000.0

    private val log = Logger.getLogger("walkies.places")

    /**
     * Lays the world grid over the place, keeps the tiles with a street or path
     * through them, then replays every past walk so the new place starts with what
     * you've done. The streets come from the server's shared cache when there's a
     * client, or straight from Overpass when there isn't or the cache can't help.
     */
    suspend fun build(
        place: PlaceResult,
        walks: List<Walk>,
        client: ConvexClient?,
        osm: OSMClient,
        status: (String) -> Unit,
    ): City {
        val osmId = place.osmId
        if (osmId != null && client != null) {
            status("Getting ${place.name} ready…")
            try {
                val cached = PlaceData.fetch(osmId, client)
                status("Laying out the tiles…")
                return withContext(Dispatchers.Default) { build(place.copy(boundary = cached.boundary), cached.ways, walks) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The local-first path still works with older deployments or an
                // unavailable cache. Cancellation should stop the add altogether.
                log.info("The street cache couldn't help with ${place.name}: $e")
                currentCoroutineContext().ensureActive()
            }
        }
        status("Finding the streets and paths…")
        val b = place.boundary.bounds
        val ways = osm.walkableWays(b.south, b.west, b.north, b.east)
        status("Laying out the tiles…")
        return withContext(Dispatchers.Default) { build(place, ways, walks) }
    }

    /** Both network paths use the same tile selection, road hints and walk replay. */
    fun build(place: PlaceResult, ways: List<OSMWay>, walks: List<Walk>): City {
        var city = build(place.name, place.detail, place.osmId, place.boundary, ways)
        val shape = city.shape()
        for (walk in walks) city = city.visit(CoverageTracer.samples(walk.points), shape).first
        return city
    }

    /** Lays the world grid over the place and keeps the tiles with a street or path through them. */
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
