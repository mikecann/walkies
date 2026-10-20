package com.mikecann.walkies.place

import com.mikecann.walkies.grid.Coordinate

/**
 * A pretend walk for the map spike, until stage 2 records real ones: down the
 * longest street in the place, then along the longest street that meets it.
 */
object SpikeWalk {
    fun route(city: City): List<Coordinate> {
        val roads = city.roads.orEmpty().filter { it.kind == RoadLine.Kind.Road }
        val first = roads.maxByOrNull { length(it.points) } ?: return emptyList()
        val joins = roads
            .filter { it !== first }
            .mapNotNull { road ->
                val end = listOf(road.points.first(), road.points.last()).firstOrNull { end ->
                    first.points.any { it.distance(end) < 15 }
                } ?: return@mapNotNull null
                road to end
            }
            .maxByOrNull { length(it.first.points) }
            ?: return first.points
        val (second, end) = joins
        // Walk the first street to the junction, then turn down the second.
        val junction = first.points.indices.minBy { first.points[it].distance(end) }
        val along = first.points.subList(0, junction + 1)
        val turn = if (second.points.first() == end) second.points else second.points.reversed()
        return along + turn
    }

    fun walk(city: City): Pair<City, List<Coordinate>> {
        val route = route(city)
        return city.visit(CityBuilder.samples(route), city.shape()).first to route
    }

    private fun length(points: List<Coordinate>) = points.zipWithNext { a, b -> a.distance(b) }.sum()
}
