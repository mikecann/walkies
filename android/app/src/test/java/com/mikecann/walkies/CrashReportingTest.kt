package com.mikecann.walkies

import org.junit.Assert.assertEquals
import org.junit.Test

/** Crash reports must never carry a location (CrashReporting.kt, CrashReportingTests.swift). */
class CrashReportingTest {
    @Test fun blanksCoordinates() {
        val cases = listOf(
            "https://nominatim.openstreetmap.org/reverse?lat=-33.6512345&lon=115.3456789&zoom=12" to
                "https://nominatim.openstreetmap.org/reverse?lat=[coord]&lon=[coord]&zoom=12",
            "fix at 51.5074, -0.1278 was 12.5 m off" to "fix at [coord], [coord] was 12.5 m off",
            "(-33.6512,115.3456)" to "([coord],[coord])",
            "Index out of range" to "Index out of range",
            "took 1.25 s, 3 of 10 tiles" to "took 1.25 s, 3 of 10 tiles",
        )
        for ((text, expected) in cases) assertEquals(expected, CrashReporting.scrubbed(text))
    }
}
