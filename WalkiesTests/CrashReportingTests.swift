import Foundation
import Testing
@testable import Walkies

/// Crash reports must never carry a location (CrashReporting.swift).
struct CrashReportingTests {
    @Test(arguments: [
        ("https://nominatim.openstreetmap.org/reverse?lat=-33.6512345&lon=115.3456789&zoom=12",
         "https://nominatim.openstreetmap.org/reverse?lat=[coord]&lon=[coord]&zoom=12"),
        ("fix at 51.5074, -0.1278 was 12.5 m off", "fix at [coord], [coord] was 12.5 m off"),
        ("(-33.6512,115.3456)", "([coord],[coord])"),
        ("Index out of range", "Index out of range"),
        ("took 1.25 s, 3 of 10 tiles", "took 1.25 s, 3 of 10 tiles"),
    ])
    func blanksCoordinates(text: String, expected: String) {
        #expect(CrashReporting.scrubbed(text) == expected)
    }
}
