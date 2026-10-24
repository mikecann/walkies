import CoreLocation
import Foundation
import simd
import Testing
@testable import Walkies

/// Places that add themselves (issue #2): what to look up or add for some spots, the
/// boundary rule, and the model adding them where you are and where you've walked.
/// AutoPlacesTest.kt checks the same on Android.
@MainActor
@Suite(.serialized)
struct AutoPlacesTests {
    let grid = HexGrid.world
    let origin = Coordinate(lat: -33.65, lon: 115.35)

    /// A square suburb `half` metres either side of `x` metres east of `origin`.
    func place(_ name: String, osmId: Int, x: Double, half: Double = 1000) -> PlaceResult {
        let centre = grid.projection.project(origin) + SIMD2(x, 0)
        let ring = [SIMD2(-half, -half), SIMD2(half, -half), SIMD2(half, half), SIMD2(-half, half), SIMD2(-half, -half)]
            .map { grid.projection.unproject(centre + $0) }
        return PlaceResult(id: osmId, name: name, detail: "Tests", kind: "suburb",
                           boundary: Boundary(polygons: [GeoPolygon(outer: ring, holes: [])]), area: 4 * half * half, osmId: osmId)
    }

    func spot(x: Double, y: Double = 0) -> Coordinate {
        grid.projection.unproject(grid.projection.project(origin) + SIMD2(x, y))
    }

    func here(x: Double, y: Double = 0, accuracy: Double = 5) -> AutoPlaces.Spot {
        AutoPlaces.Spot(point: spot(x: x, y: y), accuracy: accuracy)
    }

    /// Samples every 10 m from one spot to another, as CoverageTracer gives them.
    func track(_ from: (x: Double, y: Double), _ to: (x: Double, y: Double)) -> [Coordinate] {
        let a = SIMD2(from.x, from.y), b = SIMD2(to.x, to.y)
        let n = max(1, Int((simd_distance(a, b) / 10).rounded(.up)))
        return (0...n).map { i in
            let p = a + (b - a) * Double(i) / Double(n)
            return spot(x: p.x, y: p.y)
        }
    }

    func shape(_ place: PlaceResult) -> BoundaryShape { BoundaryShape(place.boundary, projection: grid.projection) }

    func store() -> Store {
        let base = ProcessInfo.processInfo.environment["WALKIES_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL.temporaryDirectory.appending(path: "WalkiesAutoPlacesTests")
        return Store(root: base.appending(path: UUID().uuidString))
    }

    func location(_ c: Coordinate, accuracy: Double = 5, after seconds: Double = 0, speed: Double = 1) -> CLLocation {
        CLLocation(coordinate: c.cl, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   course: 90, speed: speed, timestamp: Date.now.addingTimeInterval(seconds))
    }

    /// A finished walk east along the middle from `from` to `to` metres, a fix every 10 m.
    func walk(from: Double, to: Double, endedAt: Date) -> Walk {
        let start = endedAt.addingTimeInterval(-600)
        let points = stride(from: from, through: to, by: 10).enumerated().map { i, x in
            let c = spot(x: x)
            return TrackPoint(lat: c.lat, lon: c.lon, time: start.timeIntervalSince1970 + Double(i) * 8, accuracy: 5, speed: 1.25)
        }
        return Walk(startedAt: start, endedAt: endedAt, points: points, distance: to - from, newTiles: 0)
    }

    /// Stands in for OpenStreetMap: the suburb whose square holds the spot, and a count.
    final class FakeOSM {
        var suburbs: [PlaceResult] = []
        var lookups: [Coordinate] = []
        var inFlight = 0
        var mostAtOnce = 0
        var delay: Duration = .zero

        func lookUp(_ spot: Coordinate) async throws -> AutoPlaces.Lookup {
            lookups.append(spot)
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            defer { inFlight -= 1 }
            if delay > .zero { try await Task.sleep(for: delay) }
            let p = HexGrid.world.projection.project(spot)
            return AutoPlaces.Lookup(place: suburbs.first { BoundaryShape($0.boundary, projection: HexGrid.world.projection).contains(p) })
        }
    }

    func model(_ store: Store, osm: FakeOSM) async -> AppModel {
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.lookUpSuburb = { try await osm.lookUp($0) }
        model.buildPlace = { place, walks in CityBuilder.build(from: place, ways: [], walks: walks) }
        // As if the app had just come to the front.
        model.foreground(true)
        return model
    }

    // MARK: What to do about a spot

    @Test func aSpotInOneOfYourPlacesNeedsNothing() {
        let home = place("Home", osmId: 1, x: 0)
        let next = AutoPlaces().next(here: here(x: 100), tracks: [], places: [shape(home)], known: [], isYours: { _ in false }, now: .now)
        #expect(next == .nothing)
    }

    @Test func aSpotInAKnownNeighbourAddsItWithoutALookup() {
        let home = place("Home", osmId: 1, x: 0)
        let next = place("Next door", osmId: 2, x: 2000)
        #expect(AutoPlaces().next(here: here(x: 2100), tracks: [], places: [shape(home)], known: [home, next],
                                  isYours: { $0.osmId == 1 }, now: .now) == .add(next))
        // A neighbour you deleted, or one that's far too big, doesn't count.
        var declined = AutoPlaces()
        declined.decline(osmId: 2)
        #expect(declined.next(here: here(x: 2100), tracks: [], places: [], known: [next], isYours: { _ in false }, now: .now) == .nothing)
        let huge = place("Shire", osmId: 3, x: 2000, half: 15_000)
        #expect(AutoPlaces().next(here: here(x: 2100), tracks: [], places: [], known: [huge], isYours: { _ in false }, now: .now)
                == .lookUp(spot(x: 2100)))
    }

    @Test func aRememberedMissIsntLookedUpAgainForAMonth() {
        var auto = AutoPlaces()
        let sea = spot(x: 5000)
        auto.looked(at: sea, found: AutoPlaces.Lookup(place: nil), isYours: { _ in false }, now: .now)
        // Anywhere in the same square, about 200 m across.
        let nearby = Coordinate(lat: sea.lat, lon: (sea.lon / AutoPlaces.cellSize).rounded(.down) * AutoPlaces.cellSize + 0.0001)
        #expect(auto.next(here: nil, tracks: [[sea, nearby]], places: [], known: [], isYours: { _ in false }, now: .now) == .nothing)
        let later = Date.now.addingTimeInterval(31 * 24 * 3600)
        #expect(auto.next(here: nil, tracks: [[sea]], places: [], known: [], isYours: { _ in false }, now: later) == .lookUp(sea))
        auto.tidy(now: later)
        #expect(auto.missedUntil.isEmpty)
    }

    @Test func aMissOnlyCoversAbout200Metres() {
        var auto = AutoPlaces()
        let sea = spot(x: 5000)
        auto.looked(at: sea, found: AutoPlaces.Lookup(place: nil), isYours: { _ in false }, now: .now)
        #expect(auto.missed(at: sea, now: .now))
        // 300 m away, in any direction, is somewhere else.
        for other in [spot(x: 5300), spot(x: 4700), spot(x: 5000, y: 300), spot(x: 5000, y: -300)] {
            #expect(!auto.missed(at: other, now: .now))
        }
        #expect(AutoPlaces.cellSize * 111_320 < 250)
    }

    @Test func onlyTheFirstSpotThatNeedsItIsLookedUp() {
        let next = AutoPlaces().next(here: nil, tracks: [[spot(x: 5000), spot(x: 9000)]], places: [], known: [], isYours: { _ in false }, now: .now)
        #expect(next == .lookUp(spot(x: 5000)))
    }

    @Test func aLookupThatFindsNoSuburbIsAMissButOneOfYoursIsnt() {
        let home = place("Home", osmId: 1, x: 0)
        let tiny = place("Tiny", osmId: 4, x: 0, half: 100)
        var auto = AutoPlaces()
        // One of yours: nothing's ruled out, so the suburb over the border still can be added.
        auto.looked(at: spot(x: 100), found: AutoPlaces.Lookup(place: home), isYours: { $0.osmId == 1 }, now: .now)
        #expect(auto.found.isEmpty)
        #expect(!auto.missed(at: spot(x: 100), now: .now))
        auto.looked(at: spot(x: 3000), found: AutoPlaces.Lookup(place: tiny), isYours: { _ in false }, now: .now)
        #expect(auto.found.isEmpty)
        #expect(auto.missed(at: spot(x: 3000), now: .now))
        let found = place("Found", osmId: 5, x: 8000)
        auto.looked(at: spot(x: 8000), found: AutoPlaces.Lookup(place: found), isYours: { _ in false }, now: .now)
        #expect(auto.found == [found])
        #expect(!auto.missed(at: spot(x: 8000), now: .now))
        // A hex already asked about this time isn't asked again.
        #expect(auto.next(here: here(x: 100), tracks: [], places: [], known: [], isYours: { _ in false },
                          asked: [grid.hex(containing: spot(x: 100))], now: .now) == .nothing)
    }

    @Test func theSmallestSuburbSizedBoundaryWins() {
        let tiny = place("Tiny", osmId: 10, x: 0, half: 100)
        let suburb = place("Suburb", osmId: 9, x: 0, half: 2000)
        let shire = place("Shire", osmId: 8, x: 0, half: 15_000)
        #expect(AutoPlaces.pick([shire, suburb, tiny], order: [10, 9, 8]) == suburb)
        #expect(AutoPlaces.pick([shire], order: [8]) == nil)
        #expect(AutoPlaces.pick([], order: []) == nil)
    }

    // MARK: Borders

    @Test func openingTheAppJustOverTheBorderFromHomeDoesNothing() {
        let home = place("Home", osmId: 1, x: 0)
        let next = place("Next door", osmId: 2, x: 2000)
        let auto = AutoPlaces()
        func decide(_ spot: AutoPlaces.Spot, known: [PlaceResult] = []) -> AutoPlaces.Next {
            auto.next(here: spot, tracks: [], places: [shape(home)], known: known, isYours: { $0.osmId == 1 }, now: .now)
        }
        // Home's edge is 1000 m east. 40 m over it is GPS wobble from home.
        #expect(decide(here(x: 1040)) == .nothing)
        #expect(decide(here(x: 1040), known: [home, next]) == .nothing)
        // Far enough over to be sure.
        #expect(decide(here(x: 1060)) == .lookUp(spot(x: 1060)))
        #expect(decide(here(x: 1060), known: [home, next]) == .add(next))
        // A vaguer fix needs to be further over.
        #expect(decide(here(x: 1060, accuracy: 80)) == .nothing)
        #expect(decide(here(x: 1100, accuracy: 80)) == .lookUp(spot(x: 1100)))
    }

    @Test func walkingAlongABorderStreetAddsNothing() {
        let home = place("Home", osmId: 1, x: 0)
        let next = place("Next door", osmId: 2, x: 2000)
        let other = place("Other", osmId: 3, x: 4000)
        // Up the street on home's border, the GPS wobbling 20 m either side of it.
        var wobble: [Coordinate] = []
        for (i, y) in stride(from: -800.0, through: 800, by: 10).enumerated() {
            wobble.append(spot(x: 1000 + (i % 2 == 0 ? 20 : -20), y: y))
        }
        let auto = AutoPlaces()
        #expect(auto.next(here: nil, tracks: [wobble], places: [shape(home)], known: [], isYours: { $0.osmId == 1 }, now: .now) == .nothing)
        #expect(auto.next(here: nil, tracks: [wobble], places: [shape(home)], known: [home, next], isYours: { $0.osmId == 1 }, now: .now) == .nothing)
        // The same along a border between two suburbs that aren't yours.
        let between = wobble.map { spot(x: grid.projection.project($0).x - grid.projection.project(origin).x + 2000,
                                         y: grid.projection.project($0).y - grid.projection.project(origin).y) }
        #expect(auto.next(here: nil, tracks: [between], places: [shape(home)], known: [next, other], isYours: { $0.osmId == 1 }, now: .now) == .nothing)
        // A stray fix well in, but only one, doesn't count either.
        var stray = wobble
        stray.insert(spot(x: 1080, y: 0), at: 80)
        #expect(auto.next(here: nil, tracks: [stray], places: [shape(home)], known: [home, next], isYours: { $0.osmId == 1 }, now: .now) == .nothing)
        // Turning off it and walking 100 m in does.
        let into = track((1000, 0), (1100, 0))
        #expect(auto.next(here: nil, tracks: [wobble + into], places: [shape(home)], known: [home, next], isYours: { $0.osmId == 1 }, now: .now) == .add(next))
        #expect(AutoPlaces.wentInto(shape(next), along: into))
        #expect(!AutoPlaces.wentInto(shape(next), along: track((1000, 0), (1060, 0))))
    }

    // MARK: Waiting and backing off

    @Test func aSuburbWhoseStreetsWontDownloadWaitsLongerEachTime() {
        let abbey = place("Abbey", osmId: 21, x: 2000)
        var auto = AutoPlaces()
        let start = Date.now
        var waits: [Double] = []
        for _ in 0..<12 {
            auto.failedToBuild(abbey, now: start)
            waits.append(auto.buildFailures["21"]!.retryAt.timeIntervalSince(start).rounded())
        }
        #expect(waits.prefix(4) == [300, 600, 1200, 2400])
        #expect(waits.last == AutoPlaces.buildRetryCap)
        #expect(AutoPlaces.buildRetryCap == 86_400)
        // Waiting, it's skipped and the walks wait with it; then it's tried again.
        let walk = [track((1100, 0), (2000, 0))]
        #expect(auto.next(here: here(x: 2000), tracks: walk, places: [], known: [abbey], isYours: { _ in false }, now: start) == .later)
        #expect(auto.next(here: here(x: 2000), tracks: walk, places: [], known: [abbey], isYours: { _ in false },
                          now: start.addingTimeInterval(24 * 3600 + 1)) == .add(abbey))
        // Added in the end: it starts from scratch.
        auto.added(abbey)
        #expect(auto.buildFailures.isEmpty)
    }

    @Test func aFailedLookupWaitsAndOtherSpotsCarryOn() {
        let next = place("Next door", osmId: 2, x: 2000)
        var auto = AutoPlaces()
        auto.lookUpFailed(now: .now)
        // Nothing's asked for five minutes, but a suburb whose outline is known still adds.
        #expect(auto.next(here: here(x: 9000), tracks: [], places: [], known: [], isYours: { _ in false }, now: .now) == .later)
        #expect(auto.next(here: here(x: 2000), tracks: [], places: [], known: [next], isYours: { _ in false }, now: .now) == .add(next))
        #expect(auto.next(here: here(x: 9000), tracks: [], places: [], known: [], isYours: { _ in false },
                          now: .now.addingTimeInterval(301)) == .lookUp(spot(x: 9000)))
    }

    // MARK: The fallback

    @Test func theFallbacksAnswerFollowsTheSameRule() {
        // Nominatim's reverse lookup gives one boundary, and the country it's in.
        #expect(AutoPlaces.suburbCandidates([AutoPlaces.Relation(id: 11688696, adminLevel: "9")], country: "au") == [11688696])
        // In Australia, never the council.
        #expect(AutoPlaces.suburbCandidates([AutoPlaces.Relation(id: 11688682, adminLevel: "6")], country: "au").isEmpty)
        #expect(AutoPlaces.suburbCandidates([AutoPlaces.Relation(id: 57539, adminLevel: "6")], country: "gb") == [57539])
        #expect(AutoPlaces.suburbCandidates([AutoPlaces.Relation(id: 8005, adminLevel: "11")], country: "nl").isEmpty)
        #expect(AutoPlaces.suburbCandidates([AutoPlaces.Relation(id: 8004, adminLevel: nil)], country: "gb").isEmpty)
        // Finding nothing only rules a spot out for a day, since Overpass never answered.
        var auto = AutoPlaces()
        let spot = spot(x: 5000)
        auto.looked(at: spot, found: AutoPlaces.Lookup(place: nil, fallback: true), isYours: { _ in false }, now: .now)
        #expect(auto.missed(at: spot, now: .now.addingTimeInterval(23 * 3600)))
        #expect(!auto.missed(at: spot, now: .now.addingTimeInterval(25 * 3600)))
    }

    @Test func withOverpassDownTheFallbackNeverAddsTheCouncil() async throws {
        let session = OSMStub.session { url in
            if OSMClient.overpassEndpoints.contains(url) {
                return (200, #"{"remark":"runtime error: Query timed out","elements":[]}"#)
            }
            if url.path == "/reverse" {
                return (200, #"{"osm_type":"relation","osm_id":11688682,"extratags":{"admin_level":"6"},"address":{"country_code":"au"}}"#)
            }
            return (500, "")
        }
        let found = try await OSMClient.suburb(at: Coordinate(lat: -33.635, lon: 115.385), session: session)
        // The City of Busselton is the council, not a suburb.
        #expect(found == AutoPlaces.Lookup(place: nil, fallback: true))
        #expect(OSMStub.asked.contains { $0.path == "/reverse" && $0.query?.contains("extratags=1") == true })
        #expect(!OSMStub.asked.contains { $0.path == "/lookup" })
    }

    @Test func withOverpassDownTheFallbackFindsTheLocality() async throws {
        let session = OSMStub.session { url in
            if OSMClient.overpassEndpoints.contains(url) { return (504, "") }
            if url.path == "/reverse" {
                return (200, #"{"osm_type":"relation","osm_id":11688696,"extratags":{"admin_level":"9"},"address":{"country_code":"au"}}"#)
            }
            if url.path == "/lookup" {
                return (200, #"[{"place_id":5,"osm_type":"relation","osm_id":11688696,"name":"Geographe","geojson":{"type":"Polygon","coordinates":[[[115.38,-33.64],[115.39,-33.64],[115.39,-33.63],[115.38,-33.63],[115.38,-33.64]]]}}]"#)
            }
            return (500, "")
        }
        let found = try await OSMClient.suburb(at: Coordinate(lat: -33.635, lon: 115.385), session: session)
        #expect(found.place?.osmId == 11688696)
        #expect(found.fallback)
    }

    @Test func oneRequestAtATimeToOpenStreetMap() async throws {
        let lane = OSMLane(spacing: .milliseconds(100))
        let counter = Counter()
        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await lane.run {
                        await counter.enter(at: clock.now)
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await counter.mostAtOnce == 1)
        let starts = await counter.starts.map { start.duration(to: $0) }.sorted()
        #expect(starts[1] - starts[0] >= .milliseconds(100))
        #expect(starts[2] - starts[1] >= .milliseconds(100))
    }

    actor Counter {
        var inFlight = 0
        var mostAtOnce = 0
        var starts: [ContinuousClock.Instant] = []
        func enter(at instant: ContinuousClock.Instant) {
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            starts.append(instant)
        }
        func leave() { inFlight -= 1 }
    }

    // MARK: The rule both phones share

    struct RuleFixture: Decodable {
        struct Case: Decodable {
            struct Relation: Decodable {
                var id: Int
                var admin_level: String?
                var country: String?

                enum CodingKeys: String, CodingKey {
                    case id, admin_level
                    case country = "ISO3166-1"
                }
            }
            var name: String
            var relations: [Relation]
            var expected: [Int]
        }
        struct PlaceID: Decodable {
            var osmId: Int
            var id: UUID
        }
        var cases: [Case]
        var placeIds: [PlaceID]
    }

    func ruleFixture() throws -> RuleFixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "shared/fixtures/places/suburb-rule.json")
        return try JSONDecoder().decode(RuleFixture.self, from: Data(contentsOf: url))
    }

    @Test func theSuburbRuleMatchesTheSharedFixture() throws {
        for test in try ruleFixture().cases {
            let relations = test.relations.map { AutoPlaces.Relation(id: $0.id, adminLevel: $0.admin_level, country: $0.country) }
            #expect(AutoPlaces.suburbCandidates(relations) == test.expected, "\(test.name)")
        }
    }

    @Test func aPlaceGetsTheSameIdFromItsBoundaryOnEveryPhone() throws {
        for expected in try ruleFixture().placeIds {
            #expect(City.id(forOSM: expected.osmId) == expected.id)
        }
        let built = CityBuilder.build(from: place("Built", osmId: 123, x: 0), ways: [], walks: [])
        #expect(built.id.uuidString == "B57E647F-BA14-30F9-82D7-B1F6F899A740")
        var noRelation = place("Drawn", osmId: 0, x: 0)
        noRelation.osmId = nil
        #expect(CityBuilder.build(from: noRelation, ways: [], walks: []).id != CityBuilder.build(from: noRelation, ways: [], walks: []).id)
    }

    @Test func whatsBeenLookedUpReadsBackAndOlderFilesStillRead() throws {
        let store = store()
        defer { store.wipe() }
        var auto = AutoPlaces(walksSince: Date(timeIntervalSinceReferenceDate: 812345600))
        auto.looked(at: spot(x: 5000), found: AutoPlaces.Lookup(place: nil), isYours: { _ in false }, now: .now)
        auto.looked(at: spot(x: 2000), found: AutoPlaces.Lookup(place: place("Abbey", osmId: 21, x: 2000)), isYours: { _ in false }, now: .now)
        auto.decline(osmId: 7)
        auto.checked([walk(from: 0, to: 100, endedAt: .now)])
        auto.lookUpFailed(now: .now)
        auto.failedToBuild(place("Abbey", osmId: 21, x: 2000), now: .now)
        store.save(autoPlaces: auto)
        let read = try #require(store.loadAutoPlaces())
        #expect(read.missedUntil == auto.missedUntil)
        #expect(read.found == auto.found)
        #expect(read.declined == [7])
        #expect(read.walksSince == auto.walksSince)
        #expect(read.checkedWalks == auto.checkedWalks)
        #expect(read.lookUpAgainAt == auto.lookUpAgainAt)
        #expect(read.buildFailures == auto.buildFailures)
        // One from before most of this was kept.
        let old = try JSONDecoder().decode(AutoPlaces.self, from: Data(#"{"declined":[3],"found":[]}"#.utf8))
        #expect(old.declined == [3])
        #expect(old.walksSince == nil)
    }

    // MARK: The model

    @Test func aFreshAccountGetsTheSuburbItsIn() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        let here = place("Geographe", osmId: 11688696, x: 0)
        osm.suburbs = [here]
        let model = await model(store, osm: osm)
        var findingWhileLooking = false
        model.lookUpSuburb = { [weak model] spot in
            findingWhileLooking = model?.findingFirstPlace ?? false
            return try await osm.lookUp(spot)
        }
        // Nothing until the account's places have come down.
        model.noteWhereYouAre(location(spot(x: 100)))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.isEmpty)
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        // The place chip says it's finding your suburb meanwhile.
        #expect(findingWhileLooking)
        #expect(osm.lookups == [spot(x: 100)])
        #expect(model.cities.map(\.name) == ["Geographe"])
        #expect(model.cities.first?.id == City.id(forOSM: 11688696))
        #expect(model.selectedCityID == model.cities.first?.id)
        #expect(model.flyToSelected == 1)
        #expect(model.addedPlaceNotice == nil)
        #expect(!model.findingFirstPlace)
        #expect(model.showWalkHint)
        // Saved, so the next launch doesn't ask again.
        #expect(store.loadAutoPlaces()?.found.isEmpty == true)
    }

    @Test func openingTheAppAtHomeDoesNothing() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        let home = CityBuilder.build(from: place("Home", osmId: 1, x: 0), ways: [], walks: [])
        store.save([home])
        let model = await model(store, osm: osm)
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 300)))
        await model.waitForPlacesYouveBeen()
        // Just over the border from home, which is GPS wobble from inside it.
        model.foreground(true)
        model.noteWhereYouAre(location(spot(x: 1040)))
        await model.waitForPlacesYouveBeen()
        // A vague fix somewhere else is passed over too.
        model.foreground(true)
        model.noteWhereYouAre(location(spot(x: 9000), accuracy: 60))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.isEmpty)
        #expect(model.cities.map(\.id) == [home.id])
        #expect(model.flyToSelected == 0)
        // Still waiting for a good one, which then counts.
        #expect(model.checkSpotOnNextFix)
        model.noteWhereYouAre(location(spot(x: 9000), accuracy: 20))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups == [spot(x: 9000)])
    }

    @Test func goingToTheBackgroundStopsTheSpotCheck() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 0)]
        let model = await model(store, osm: osm)
        // Opened indoors with no good fix, then closed: a fix from later, in a car on
        // the way somewhere, say, doesn't count.
        model.foreground(false)
        #expect(!model.checkSpotOnNextFix)
        model.noteWhereYouAre(location(spot(x: 100)))
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.isEmpty)
        // A spot taken but not checked yet (the account hadn't come down) is dropped too.
        let otherStore = self.store()
        defer { otherStore.wipe() }
        let other = await self.model(otherStore, osm: osm)
        other.noteWhereYouAre(location(spot(x: 100)))
        other.foreground(false)
        other.pulledAccount()
        await other.waitForPlacesYouveBeen()
        #expect(osm.lookups.isEmpty)
        #expect(model.cities.isEmpty)
    }

    @Test func aFixFromACarIsPassedOver() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 0)]
        let model = await model(store, osm: osm)
        model.pulledAccount()
        // Faster than a walk.
        model.noteWhereYouAre(location(spot(x: 100), speed: 15))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.isEmpty)
        #expect(model.checkSpotOnNextFix)
        // Out of the car and on foot, with the app still open.
        model.noteWhereYouAre(location(spot(x: 100), speed: 1))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.count == 1)
        #expect(model.cities.map(\.name) == ["Abbey"])
    }

    @Test func signingOutInTheBackgroundDoesntArmTheSpotCheck() async throws {
        let store = store()
        defer { store.wipe() }
        let model = await model(store, osm: FakeOSM())
        model.foreground(false)
        model.wipeLocalData()
        #expect(!model.checkSpotOnNextFix)
        model.foreground(true)
        model.wipeLocalData()
        #expect(model.checkSpotOnNextFix)
    }

    @Test func aWalkAcrossTwoNewSuburbsAddsEachOnce() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        let a = place("Abbey", osmId: 21, x: 2000)
        let b = place("Broadwater", osmId: 22, x: 4000)
        osm.suburbs = [a, b]
        let home = CityBuilder.build(from: place("Home", osmId: 20, x: 0), ways: [], walks: [])
        store.save([home])
        let model = await model(store, osm: osm)
        model.checkSpotOnNextFix = false
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        model.startWalk()
        // From home, through Abbey and into Broadwater, 50 m every 40 seconds. Clear of
        // the borders, so no spot is exactly on one.
        for (i, x) in stride(from: 505.0, through: 3605, by: 50).enumerated() {
            model.tracker.onLocation?(location(spot(x: x), after: Double(i) * 40))
        }
        model.endWalk()
        await model.waitForPlacesYouveBeen()
        #expect(model.cities.map(\.name).sorted() == ["Abbey", "Broadwater", "Home"])
        #expect(osm.lookups.count == 2)
        // The walk's tiles count in both.
        #expect(model.cities.allSatisfy { !$0.visited.isEmpty })
        // You were already looking at home, so that stays and a note says what's new.
        #expect(model.selectedCityID == home.id)
        #expect(model.addedPlaceNotice?.name == "Broadwater")
        // Done with that walk: opening the app again asks nothing.
        model.addPlacesYouveBeen()
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.count == 2)
    }

    @Test func theWalkYoureOnCountsInAPlaceThatAddsItselfPartway() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 2000)]
        let home = CityBuilder.build(from: place("Home", osmId: 20, x: 0), ways: [], walks: [])
        store.save([home])
        let model = await model(store, osm: osm)
        model.checkSpotOnNextFix = false
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        model.startWalk()
        // Ten minutes into a walk from home into Abbey, the app's opened.
        for (i, x) in stride(from: 505.0, through: 2005, by: 50).enumerated() {
            model.tracker.onLocation?(location(spot(x: x), after: Double(i) * 20))
        }
        let walked = Set(CoverageTracer.samples(for: try #require(model.activeWalk).points).map { grid.hex(containing: $0) })
        model.foreground(true)
        model.noteWhereYouAre(location(spot(x: 2005), after: 31 * 20))
        await model.waitForPlacesYouveBeen()
        let abbey = try #require(model.cities.first { $0.name == "Abbey" })
        let inAbbey = walked.filter { BoundaryShape(abbey.boundary, projection: grid.projection).contains(grid.centre(of: $0)) }
        #expect(!inAbbey.isEmpty)
        #expect(inAbbey.isSubset(of: abbey.visited))
        // New on this walk, so the summary and quests see them.
        #expect(model.freshTiles[abbey.id]?.isEmpty == false)
        model.endWalk()
        await model.waitForPlacesYouveBeen()
        let walk = try #require(model.walks.last)
        #expect(walk.newTileHexesByPlace?[abbey.id.uuidString]?.isEmpty == false)
        // The walk's end finds nothing more to add.
        #expect(osm.lookups.count == 1)
    }

    @Test func addingAPlaceByHandPartwayThroughAWalkCountsTheWalk() async throws {
        let store = store()
        defer { store.wipe() }
        let model = await model(store, osm: FakeOSM())
        let abbey = place("Abbey", osmId: 21, x: 2000)
        model.startWalk()
        for (i, x) in stride(from: 1505.0, through: 2505, by: 50).enumerated() {
            model.tracker.onLocation?(location(spot(x: x), after: Double(i) * 20))
        }
        try await model.addPlace(abbey) { _ in }
        let added = try #require(model.cities.first)
        #expect(!added.visited.isEmpty)
        #expect(model.freshTiles[added.id] == added.visited)

        // A walk that ends while the place is being built counts too.
        let otherStore = self.store()
        defer { otherStore.wipe() }
        let other = await self.model(otherStore, osm: FakeOSM())
        other.startWalk()
        for (i, x) in stride(from: 1505.0, through: 2505, by: 50).enumerated() {
            other.tracker.onLocation?(location(spot(x: x), after: Double(i) * 20))
        }
        other.buildPlace = { [weak other] place, walks in
            other?.endWalk()
            return CityBuilder.build(from: place, ways: [], walks: walks)
        }
        try await other.addPlace(abbey) { _ in }
        #expect(other.activeWalk == nil)
        #expect(other.cities.first?.visited.isEmpty == false)
    }

    @Test func anOlderWalkThatDownloadsLaterIsStillLookedAt() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 2000), place("Broadwater", osmId: 22, x: -2000)]
        let model = await model(store, osm: osm)
        model.checkSpotOnNextFix = false
        let since = try #require(model.autoPlaces.walksSince)
        // The 11:00 walk comes down first, then the 10:00 one.
        let later = walk(from: 1500, to: 2500, endedAt: since.addingTimeInterval(120))
        let earlier = walk(from: -2500, to: -1500, endedAt: since.addingTimeInterval(60))
        await model.addRemote(cities: [], walks: [later], progress: nil, secrets: [:])
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(model.cities.map(\.name) == ["Abbey"])
        await model.addRemote(cities: [], walks: [earlier], progress: nil, secrets: [:])
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(model.cities.map(\.name).sorted() == ["Abbey", "Broadwater"])
        #expect(Set(model.autoPlaces.checkedWalks.keys) == [later.id.uuidString, earlier.id.uuidString])
        // A walk from before the update never adds anything, however late it comes.
        osm.suburbs.append(place("Carbunup", osmId: 23, x: 6000))
        let before = walk(from: 5500, to: 6500, endedAt: since.addingTimeInterval(-60))
        await model.addRemote(cities: [], walks: [before], progress: nil, secrets: [:])
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(model.cities.count == 2)
        #expect(osm.lookups.count == 2)
    }

    @Test func oneLookupAtATime() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.delay = .milliseconds(50)
        let model = await model(store, osm: osm)
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 50_000)))
        model.addPlacesYouveBeen()
        model.pulledAccount()
        model.addPlacesYouveBeen()
        await model.waitForPlacesYouveBeen()
        #expect(osm.mostAtOnce == 1)
        // Nothing there: the sea, say. Remembered, so it isn't asked about again.
        #expect(osm.lookups.count == 1)
        model.foreground(true)
        model.noteWhereYouAre(location(spot(x: 50_000)))
        await model.waitForPlacesYouveBeen()
        #expect(osm.lookups.count == 1)
        #expect(model.cities.isEmpty)
    }

    @Test func aFailedLookupWaitsBeforeTryingAgainEvenAfterARelaunch() async throws {
        let store = store()
        defer { store.wipe() }
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var calls = 0
        model.lookUpSuburb = { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        model.foreground(true)
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 0)))
        await model.waitForPlacesYouveBeen()
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(calls == 1)
        #expect(!model.findingFirstPlace)
        #expect(model.autoPlaces.missedUntil.isEmpty)
        // iOS relaunching the app in the background doesn't skip the wait.
        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await relaunched.waitForHistory()
        relaunched.lookUpSuburb = model.lookUpSuburb
        relaunched.foreground(true)
        relaunched.pulledAccount()
        relaunched.noteWhereYouAre(location(spot(x: 0)))
        await relaunched.waitForPlacesYouveBeen()
        #expect(calls == 1)
        #expect(relaunched.autoPlaces.lookUpAgainAt != nil)
    }

    @Test func aSuburbThatWontBuildWaitsItsTurnEvenAfterARelaunch() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 0)]
        let model = await model(store, osm: osm)
        var builds = 0
        model.buildPlace = { _, _ in
            builds += 1
            throw URLError(.timedOut)
        }
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 100)))
        await model.waitForPlacesYouveBeen()
        #expect(builds == 1)
        #expect(model.autoPlaces.found.map(\.osmId) == [21])
        #expect(model.autoPlaces.buildFailures["21"]?.count == 1)
        model.pulledAccount()
        await model.waitForPlacesYouveBeen()
        #expect(builds == 1)
        let relaunched = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await relaunched.waitForHistory()
        relaunched.lookUpSuburb = model.lookUpSuburb
        relaunched.buildPlace = model.buildPlace
        relaunched.foreground(true)
        relaunched.pulledAccount()
        relaunched.noteWhereYouAre(location(spot(x: 100)))
        await relaunched.waitForPlacesYouveBeen()
        #expect(builds == 1)
        // Found once: no more lookups while it waits.
        #expect(osm.lookups.count == 1)
    }

    @Test func aPlaceYouDeleteDoesntAddItselfAgain() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        osm.suburbs = [place("Abbey", osmId: 21, x: 0)]
        let model = await model(store, osm: osm)
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 100)))
        await model.waitForPlacesYouveBeen()
        let added = try #require(model.cities.first)
        model.deleteCity(added.id)
        for _ in 0..<2 {
            model.foreground(true)
            model.noteWhereYouAre(location(spot(x: 100)))
            await model.waitForPlacesYouveBeen()
        }
        #expect(model.cities.isEmpty)
        #expect(model.autoPlaces.declined == [21])
        // One more look to learn the spot's in a place you deleted, and then no more.
        #expect(osm.lookups.count == 2)
    }

    @Test func aPlaceDeletedWhileItsBuildingIsntAdded() async throws {
        let store = store()
        defer { store.wipe() }
        let osm = FakeOSM()
        let abbey = place("Abbey", osmId: 21, x: 0)
        osm.suburbs = [abbey]
        let model = await model(store, osm: osm)
        // Meanwhile it comes down from the account and you delete it.
        model.buildPlace = { [weak model] place, walks in
            let city = CityBuilder.build(from: place, ways: [], walks: walks)
            model?.add(city)
            model?.deleteCity(city.id)
            return city
        }
        model.pulledAccount()
        model.noteWhereYouAre(location(spot(x: 100)))
        await model.waitForPlacesYouveBeen()
        #expect(model.cities.isEmpty)
        #expect(model.autoPlaces.declined == [21])
        #expect(model.addedPlaceNotice == nil)
    }

    @Test func twoCopiesOfOneSuburbBothStay() async throws {
        let store = store()
        defer { store.wipe() }
        let suburb = place("Abbey", osmId: 21, x: 0)
        var mine = CityBuilder.build(from: suburb, ways: [], walks: [])
        mine.id = UUID()
        let hexes = Array(mine.tiles)
        mine.visited = [hexes[0]]
        var theirs = mine
        theirs.id = UUID()
        theirs.visited = [hexes[1]]
        store.save([mine])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        var deleted: [UUID] = []
        model.placesDeleted = { deleted += $0 }
        await model.addRemote(cities: [theirs], walks: [], progress: nil, secrets: [:])
        // An older version added it on another phone with its own id. Both stay, as
        // they were: nothing's deleted from the account that you didn't delete.
        #expect(Set(model.cities.map(\.id)) == [mine.id, theirs.id])
        #expect(model.cities.first { $0.id == mine.id }?.visited == [hexes[0]])
        #expect(model.cities.first { $0.id == theirs.id }?.visited == [hexes[1]])
        #expect(deleted.isEmpty)
        store.flush()
        #expect(store.loadCities().count == 2)
    }

    @Test func addingASuburbYouHaveJustGoesThere() async throws {
        let store = store()
        defer { store.wipe() }
        let home = CityBuilder.build(from: place("Home", osmId: 1, x: 0), ways: [], walks: [])
        let model = AppModel(store: store, servicesEnabled: false, alwaysOn: false)
        await model.waitForHistory()
        model.add(home)
        model.add(CityBuilder.build(from: place("Home", osmId: 1, x: 0), ways: [], walks: []))
        #expect(model.cities.count == 1)
    }
}

/// Answers OSMClient's requests in place of OpenStreetMap.
nonisolated final class OSMStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (URL) -> (Int, String) = { _ in (500, "") }
    nonisolated(unsafe) static var asked: [URL] = []

    static func session(_ answer: @escaping (URL) -> (Int, String)) -> URLSession {
        Self.answer = answer
        asked = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OSMStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.asked.append(url)
        let (status, body) = Self.answer(url)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
