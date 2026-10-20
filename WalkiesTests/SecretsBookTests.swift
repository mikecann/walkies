import Foundation
import Testing
@testable import Walkies

struct SecretsBookTests {
    let origin = Coordinate(lat: -33.638, lon: 115.386)
    let foundAt = Date(timeIntervalSince1970: 1000)

    func entry(_ id: String, area: String? = nil, east: Double? = nil) -> LoreEntry {
        let coordinate = east.map { LocalProjection(origin: origin).unproject(SIMD2($0, 0)) }
        return LoreEntry(
            id: id, title: id, body: "", category: "history",
            place: coordinate.map { LoreEntry.Place(name: id, lat: $0.lat, lon: $0.lon) },
            sticker: "", sources: [], suburb: area
        )
    }

    func city(_ name: String, east: Double = 0) -> City {
        let projection = LocalProjection(origin: origin)
        let corners = [SIMD2(east - 100, -100), SIMD2(east + 100, -100), SIMD2(east + 100, 100), SIMD2(east - 100, 100)]
        return City(
            name: name, detail: "Busselton",
            boundary: Boundary(polygons: [GeoPolygon(outer: corners.map(projection.unproject), holes: [])]),
            tiles: [], visited: []
        )
    }

    @Test func groupsEveryEntryAndKeepsOverallCounts() {
        let entries = [entry("one", area: "Geographe"), entry("two", area: "Geographe"), entry("three", area: "Ludlow")]
        let sections = SecretsBook.sections(entries: entries, found: ["one": foundAt], location: nil, places: [city("geographe")])
        #expect(sections.map(\.name) == ["Geographe", "Ludlow"])
        #expect(sections[0].total == 2)
        #expect(sections[0].found == 1)
        #expect(sections[0].progress == 0.5)
        #expect(sections[0].isAdded)
        #expect(!sections[1].isAdded)
        #expect(sections.flatMap(\.entries).count == entries.count)
    }

    @Test func missingSuburbGoesAroundBusselton() {
        let sections = SecretsBook.sections(entries: [entry("general"), entry("jetty", east: 100)], found: [:], location: nil, places: [])
        #expect(sections.count == 1)
        #expect(sections.first?.name == "Around Busselton")
        #expect(sections.first?.total == 2)
    }

    @Test func currentAreaMatchesSelectedCityIgnoringCase() {
        let entries = [entry("one", area: "Geographe"), entry("two", area: "Ludlow")]
        #expect(SecretsBook.currentAreaName(entries: entries, selectedCityName: "geographe") == "Geographe")
        #expect(SecretsBook.currentAreaName(entries: entries, selectedCityName: "Ludlow") == "Ludlow")
    }

    @Test func noCurrentAreaWithoutMatchingCity() {
        let entries = [entry("one", area: "Geographe")]
        #expect(SecretsBook.currentAreaName(entries: entries, selectedCityName: nil) == nil)
        #expect(SecretsBook.currentAreaName(entries: entries, selectedCityName: "Ludlow") == nil)
        #expect(SecretsBook.currentAreaName(entries: [], selectedCityName: "Geographe") == nil)
    }

    @Test func currentAreaUsesTheSameFallbackNameAsSections() {
        #expect(SecretsBook.currentAreaName(entries: [entry("general")], selectedCityName: "Around Busselton") == "Around Busselton")
    }

    @Test func currentAreaStillMatchesWhenFilterHidesIt() {
        let entries = [entry("one", area: "Geographe"), entry("two", area: "Ludlow")]
        let sections = SecretsBook.sections(entries: entries, found: ["two": foundAt], location: nil, places: [], filter: .found)
        #expect(sections.map(\.name) == ["Ludlow"])
        #expect(SecretsBook.currentAreaName(entries: entries, selectedCityName: "Geographe") == "Geographe")
    }

    @Test func nearestUsesClosestPinAndLeavesUnpinnedAreasLast() {
        let entries = [
            entry("far", area: "Zebra", east: 2000), entry("near", area: "Zebra", east: 100),
            entry("middle", area: "Bay", east: 500), entry("no-pin", area: "Apple")
        ]
        let sections = SecretsBook.sections(entries: entries, found: [:], location: origin, places: [])
        #expect(sections.map(\.name) == ["Zebra", "Bay", "Apple"])
        #expect(abs((sections[0].distance ?? 0) - 100) < 1)
        #expect(sections.last?.distance == nil)
    }

    @Test func alphabeticalIgnoresDistanceAndFinds() {
        let entries = [entry("z", area: "Zebra", east: 10), entry("a", area: "Apple", east: 2000)]
        let sections = SecretsBook.sections(entries: entries, found: ["z": foundAt], location: origin, places: [], sort: .alphabetical)
        #expect(sections.map(\.name) == ["Apple", "Zebra"])
    }

    @Test func mostFoundUsesCountThenName() {
        let entries = [
            entry("z1", area: "Zebra"), entry("z2", area: "Zebra"), entry("z3", area: "Zebra"),
            entry("a", area: "Apple"), entry("b", area: "Bay"), entry("c", area: "Creek")
        ]
        let sections = SecretsBook.sections(
            entries: entries, found: ["z1": foundAt, "z2": foundAt, "a": foundAt, "b": foundAt],
            location: nil, places: [], sort: .mostFound
        )
        #expect(sections.map(\.name) == ["Zebra", "Apple", "Bay", "Creek"])
    }

    @Test func foundFilterHidesEmptyAreasButKeepsFullProgressAndDistance() {
        let entries = [entry("found", area: "Bay", east: 500), entry("hidden", area: "Bay", east: 100), entry("elsewhere", area: "Creek")]
        let sections = SecretsBook.sections(entries: entries, found: ["found": foundAt], location: origin, places: [], filter: .found)
        #expect(sections.count == 1)
        #expect(sections[0].entries.map(\.id) == ["found"])
        #expect(sections[0].found == 1)
        #expect(sections[0].total == 2)
        // Changing the filter mustn't make an area's distance point to a different spot.
        #expect(abs((sections[0].distance ?? 0) - 100) < 1)
    }

    @Test func notFoundFilterHidesCompletedAreas() {
        let entries = [entry("found", area: "Bay"), entry("hidden", area: "Bay"), entry("done", area: "Creek")]
        let sections = SecretsBook.sections(entries: entries, found: ["found": foundAt, "done": foundAt], location: nil, places: [], filter: .notFound)
        #expect(sections.map(\.name) == ["Bay"])
        #expect(sections[0].entries.map(\.id) == ["hidden"])
        #expect(sections[0].found == 1)
        #expect(sections[0].total == 2)
    }

    @Test func noFixFallsBackToSelectedBoundaryCentre() {
        let entries = [entry("a", area: "Apple", east: 100), entry("z", area: "Zebra", east: 1900)]
        let selected = city("Home", east: 2000)
        let sections = SecretsBook.sections(entries: entries, found: [:], location: nil, places: [selected], selectedCity: selected)
        #expect(sections.map(\.name) == ["Zebra", "Apple"])
        #expect(abs((sections[0].distance ?? 0) - 100) < 1)
        let withFix = SecretsBook.sections(entries: entries, found: [:], location: origin, places: [selected], selectedCity: selected)
        #expect(withFix.map(\.name) == ["Apple", "Zebra"])
    }

    @Test func noFixOrSelectionFallsBackToNamesEvenWithPlaces() {
        let entries = [entry("z", area: "Zebra", east: 10), entry("a", area: "Apple", east: 2000)]
        let sections = SecretsBook.sections(entries: entries, found: [:], location: nil, places: [city("Home")])
        #expect(sections.map(\.name) == ["Apple", "Zebra"])
        #expect(sections.allSatisfy { $0.distance == nil })
    }

    @Test func findsAreNewestFirstWithMysteriesAfterwards() {
        let entries = [entry("a"), entry("b"), entry("c"), entry("d")]
        let sections = SecretsBook.sections(entries: entries, found: ["c": foundAt, "b": foundAt.addingTimeInterval(10)], location: nil, places: [])
        #expect(sections[0].entries.map(\.id) == ["b", "c", "a", "d"])
    }

    @Test func emptyLibraryAndEmptyFiltersHaveNoSections() {
        #expect(SecretsBook.sections(entries: [], found: [:], location: origin, places: []).isEmpty)
        #expect(SecretsBook.sections(entries: [entry("hidden")], found: [:], location: nil, places: [], filter: .found).isEmpty)
    }
}
