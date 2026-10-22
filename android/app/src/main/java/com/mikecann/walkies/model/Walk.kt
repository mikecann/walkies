package com.mikecann.walkies.model

import com.mikecann.walkies.grid.Coordinate
import com.mikecann.walkies.grid.Hex
import com.mikecann.walkies.grid.HexGrid
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.max

data class TrackPoint(
    val lat: Double,
    val lon: Double,
    /** Seconds since 1970. */
    val time: Double,
    /** Horizontal accuracy in metres. Negative means invalid. */
    val accuracy: Double,
    /**
     * Speed from the GPS itself (Doppler), in m/s, when it had one. Far steadier
     * than working it out from the distance between two fixes.
     */
    val speed: Double? = null,
    /** The motion chip thought you were on a bike or in a car at the time. */
    val wheels: Boolean? = null,
    /** The motion chip thought you were standing still. */
    val still: Boolean? = null,
) {
    val coordinate get() = Coordinate(lat, lon)
}

data class Walk(
    val id: UUID = UUID.randomUUID(),
    val startedAt: SwiftDate,
    val endedAt: SwiftDate? = null,
    /**
     * Every fix we got, good or bad. Coverage is always recomputed from these,
     * so changing the filters or adding a city later uses the full history.
     */
    val points: List<TrackPoint> = emptyList(),
    /** Null when counting was off or the phone had no count. */
    val steps: Int? = null,
    val distance: Double = 0.0,
    val gridVersion: Int? = HexGrid.VERSION,
    val newTiles: Int = 0,
    /** Counting tiles first uncovered on this walk, by place UUID. Null on older saves. */
    val newTilesByPlace: Map<String, Int>? = null,
    /** Fresh hex identities let migrations deduplicate against saved walks without GPS replay. */
    val newTileHexesByPlace: Map<String, Set<Hex>>? = null,
    /** Tiles added to the counting grid on this walk, for an exact pre-walk recap. */
    val addedTilesByPlace: Map<String, Set<Hex>>? = null,
    /** Recorded by always-on mode rather than started with the button. */
    val automatic: Boolean? = null,
) {
    val isAutomatic get() = automatic == true

    /** Seconds, up to now for a walk still going. */
    fun duration(now: SwiftDate = SwiftDate.now()) = (endedAt ?: now).sinceReference - startedAt.sinceReference

    /** For a walk from the old grid: forget its tiles, which are worked out again from its points. */
    fun resetGridCoverage() = copy(
        gridVersion = HexGrid.VERSION,
        newTiles = 0,
        newTilesByPlace = null,
        newTileHexesByPlace = null,
        addedTilesByPlace = null,
    )
}

/** The uppercase form Swift's `uuidString` uses, for ids and dictionary keys in the files. */
val UUID.uuidString: String get() = toString().uppercase()

/** Turns a stream of GPS fixes into the spots we count as "been there". */
class CoverageTracer {
    class Step(
        val samples: List<Coordinate>,
        val distance: Double,
        /** Start of this accepted segment, for routes without bridging rejected fixes. */
        val origin: Coordinate? = null,
        /** When you were at `origin` (seconds since 1970). */
        val originTime: Double? = null,
    ) {
        companion object {
            val none = Step(emptyList(), 0.0)
        }
    }

    /**
     * The last spot that counted. New fixes are measured from here, not from the
     * previous fix, so lots of tiny wobbles never add up.
     */
    var anchor: TrackPoint? = null
        private set

    fun add(point: TrackPoint): Step {
        if (point.accuracy < 0 || point.accuracy > MAX_ACCURACY) return Step.none
        // On a bike or in a car: start again from scratch once you're back on foot.
        if (point.wheels == true || (point.speed ?: 0.0) > MAX_SPEED) {
            anchor = null
            return Step.none
        }
        // Standing still: wait, keeping the anchor where it was.
        if (point.still == true) return Step.none
        point.speed?.let { if (it < MIN_SPEED) return Step.none }
        // A spot only counts once you've walked on from somewhere that counted, so the
        // first fix after launch or a GPS jump can't sneak a tile in.
        val prev = anchor
        if (prev == null) {
            anchor = point
            return Step.none
        }

        val d = prev.coordinate.distance(point.coordinate)
        if (d < max(MIN_STEP, point.accuracy)) return Step.none
        anchor = point
        val dt = point.time - prev.time
        // Creeping that far over minutes with no speed reading is the GPS drifting, not
        // walking: walking gives a fix every second or two.
        if (point.speed == null && dt > MAX_DRIFT_GAP) return Step.none
        if (dt > 0 && d / dt > MAX_SPEED_BETWEEN_FIXES) return Step.none
        if (d > MAX_GAP) return Step.none

        val n = max(1, ceil(d / SPACING).toInt())
        val samples = (1..n).map { prev.coordinate.lerp(point.coordinate, it.toDouble() / n) }
        return Step(samples, d, prev.coordinate, prev.time)
    }

    class Timed(val samples: List<Coordinate>, val times: List<Double>)

    companion object {
        /** Fixes less accurate than this (metres) are ignored. */
        const val MAX_ACCURACY = 30.0
        /**
         * Faster than a jog (m/s, about 12 km/h) doesn't count, so cycling
         * and driving don't uncover anything. Checked against the GPS's own speed reading.
         */
        const val MAX_SPEED = 3.3
        /** Slower than this (m/s) by the GPS's own speed reading is standing about, not walking. */
        const val MIN_SPEED = 0.4
        /**
         * You have to get at least this far (metres) from the last counted spot, and further
         * than the GPS's own error, before it counts. Otherwise the GPS wobbling round one
         * spot indoors adds up to a walk.
         */
        const val MIN_STEP = 8.0
        /** Seconds since the last counted spot after which a fix with no speed reading is treated as drift. */
        const val MAX_DRIFT_GAP = 60.0
        /** The same speed check between counted spots is noisier, so it gets some slack. */
        const val MAX_SPEED_BETWEEN_FIXES = 5.0
        /** Don't join the dots across a GPS dropout longer than this (metres). */
        const val MAX_GAP = 150.0
        /** Spacing (metres) of the points we sample between fixes. */
        const val SPACING = 10.0

        /** How far these points really walked, by the same rules. */
        fun distance(points: List<TrackPoint>): Double {
            val tracer = CoverageTracer()
            return points.fold(0.0) { total, point -> total + tracer.add(point).distance }
        }

        fun samples(points: List<TrackPoint>): List<Coordinate> = timedSamples(points).samples

        /**
         * The samples, each with when you passed it (seconds since 1970), spread evenly
         * between the two fixes either side.
         */
        fun timedSamples(points: List<TrackPoint>): Timed {
            val tracer = CoverageTracer()
            val samples = ArrayList<Coordinate>()
            val times = ArrayList<Double>()
            for (point in points) {
                val step = tracer.add(point)
                val start = step.originTime ?: point.time
                for ((i, sample) in step.samples.withIndex()) {
                    samples.add(sample)
                    times.add(start + (point.time - start) * (i + 1) / step.samples.size)
                }
            }
            return Timed(samples, times)
        }
    }
}
