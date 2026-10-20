package com.mikecann.walkies.model

import kotlin.math.floor

/**
 * Swift's `Date`, kept as it's stored: seconds since 2001-01-01 (the reference date),
 * which is how `JSONEncoder` writes it by default. Keeping the raw number means a
 * date read from an iPhone file is written back bit for bit.
 */
@JvmInline
value class SwiftDate(val sinceReference: Double) : Comparable<SwiftDate> {
    /** Seconds since 1970, like `timeIntervalSince1970`. */
    val epochSeconds: Double get() = sinceReference + REFERENCE_EPOCH

    /** Milliseconds since 1970, rounded down, how Convex likes its times (`Date.ms` in Sync.swift). */
    val ms: Double get() = floor(epochSeconds * 1000)

    fun plus(seconds: Double) = SwiftDate(sinceReference + seconds)

    override fun compareTo(other: SwiftDate) = sinceReference.compareTo(other.sinceReference)

    companion object {
        /** 2001-01-01T00:00:00Z in seconds since 1970. */
        const val REFERENCE_EPOCH = 978_307_200.0

        fun epoch(seconds: Double) = SwiftDate(seconds - REFERENCE_EPOCH)

        fun now() = epoch(System.currentTimeMillis() / 1000.0)

        /** `Date.distantFuture`, which Progression uses for secrets found by exploring. */
        val distantFuture = SwiftDate(63_113_904_000.0)
        val distantPast = SwiftDate(-63_114_076_800.0)
    }
}
