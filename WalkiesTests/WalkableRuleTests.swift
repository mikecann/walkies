import Testing
@testable import Walkies

/// Sample OSM ways, by their tags. Keep in step with convex/placeData.test.ts and WalkableRuleTest.kt.
struct WalkableRuleTests {
    nonisolated static let walkableTags: [[String: String]] = [
        ["highway": "residential"],
        ["highway": "footway"],
        ["highway": "footway", "footway": "sidewalk"],
        ["highway": "cycleway", "maxspeed": "80"],
        ["highway": "secondary", "maxspeed": "60"],
        ["highway": "primary", "sidewalk": "both"],
        ["highway": "primary", "sidewalk": "left"],
        ["highway": "trunk", "sidewalk": "separate"],
        ["highway": "trunk_link", "sidewalk:left": "yes"],
        ["highway": "primary_link", "sidewalk:both": "separate"],
        ["highway": "trunk", "foot": "designated"],
        ["highway": "primary", "foot": "permissive"],
        ["highway": "primary", "footway": "sidewalk"],
        ["highway": "trunk", "foot": "yes", "maxspeed": "100"],
        ["highway": "secondary", "maxspeed": "90", "sidewalk": "right"],
        ["highway": "tertiary", "maxspeed": "40 mph"],
        ["highway": "unclassified", "maxspeed": "AU:rural"],
    ]
    nonisolated static let unwalkableTags: [[String: String]] = [
        ["highway": "motorway"],
        ["highway": "motorway_link", "sidewalk": "both"],
        ["highway": "trunk"],
        ["highway": "trunk_link"],
        ["highway": "primary"],
        ["highway": "primary_link"],
        ["highway": "primary", "sidewalk": "no"],
        ["highway": "trunk", "sidewalk": "none", "sidewalk:left": "no"],
        ["highway": "secondary", "maxspeed": "80"],
        ["highway": "tertiary", "maxspeed": "100 km/h"],
        ["highway": "unclassified", "maxspeed": "50 mph"],
        ["highway": "secondary", "maxspeed": "80", "foot": "permissive"],
        ["highway": "residential", "access": "private"],
        ["highway": "service", "foot": "no"],
        ["highway": "construction"],
        [:],
    ]

    @Test(arguments: walkableTags) func walkable(_ tags: [String: String]) {
        #expect(WalkableRule.isWalkable(tags))
    }

    @Test(arguments: unwalkableTags) func unwalkable(_ tags: [String: String]) {
        #expect(!WalkableRule.isWalkable(tags))
    }

    @Test func speedLimitsReadKmhAndMph() {
        #expect(WalkableRule.speedLimit("80") == 80)
        #expect(WalkableRule.speedLimit("80 km/h") == 80)
        #expect(WalkableRule.speedLimit(" 70kmh") == 70)
        #expect(abs(WalkableRule.speedLimit("50 mph")! - 80.47) < 0.01)
        #expect(WalkableRule.speedLimit("none") == nil)
        #expect(WalkableRule.speedLimit("AU:urban") == nil)
        #expect(WalkableRule.speedLimit(nil) == nil)
    }
}
