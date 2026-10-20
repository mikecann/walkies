import Foundation
import Testing
@testable import Walkies

struct CachedPlaceTests {
    let outline = [
        [115.380, -33.640], [115.390, -33.640], [115.390, -33.630],
        [115.380, -33.630], [115.380, -33.640],
    ]
    let hole = [
        [115.384, -33.636], [115.386, -33.636], [115.386, -33.634],
        [115.384, -33.634], [115.384, -33.636],
    ]

    func point(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }
    var ways: [OSMWay] {
        [
            OSMWay(tags: ["highway": "residential"], points: [point(-33.638, 115.381), point(-33.638, 115.389)]),
            OSMWay(tags: ["highway": "path", "access": "yes", "foot": "yes"], points: [point(-33.639, 115.382), point(-33.631, 115.382)]),
            OSMWay(tags: ["highway": "service", "service": "driveway"], points: [point(-33.632, 115.387), point(-33.631, 115.389)]),
            OSMWay(tags: ["highway": "footway", "footway": "sidewalk"], points: [point(-33.633, 115.387), point(-33.633, 115.389)]),
            OSMWay(tags: ["highway": "footway", "footway": "crossing"], points: [point(-33.632, 115.381), point(-33.632, 115.383)]),
            OSMWay(tags: ["highway": "footway", "footway": "traffic_island"], points: [point(-33.637, 115.387), point(-33.637, 115.389)]),
            OSMWay(tags: ["highway": "service", "service": "parking_aisle"], points: [point(-33.631, 115.384), point(-33.631, 115.386)]),
            OSMWay(tags: ["highway": "service", "service": "drive-through"], points: [point(-33.635, 115.381), point(-33.635, 115.383)]),
        ]
    }
    var boundary: Boundary {
        Boundary(polygons: [GeoPolygon(outer: outline.map { point($0[1], $0[0]) }, holes: [hole.map { point($0[1], $0[0]) }])])
    }
    var place: PlaceResult { PlaceResult(id: 5, name: "Test suburb", detail: "WA", kind: "suburb", boundary: boundary, area: 1_000_000, osmId: 123) }

    func file(ways: [OSMWay]) throws -> Data {
        let streets: [[String: Any]] = ways.map { way in
            var value: [String: Any] = way.tags
            value["points"] = way.points.map { [$0.lat, $0.lon] }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["boundary": [[outline, hole]], "ways": streets])
    }

    @Test func cachedCityMatchesOverpassIncludingReplayOnWorldGrid() throws {
        let cached = try JSONDecoder().decode(CachedPlaceData.self, from: file(ways: ways))
        #expect(cached.boundary == boundary)
        #expect(cached.ways.map(\.tags) == ways.map(\.tags))
        #expect(cached.ways.map(\.points) == ways.map(\.points))
        let walk = Walk(startedAt: Date(timeIntervalSince1970: 1000), points: (0...6).map { n in
            TrackPoint(lat: -33.638, lon: 115.381 + Double(n) * 0.0002, time: 1000 + Double(n) * 20, accuracy: 5, speed: 1)
        })
        let direct = CityBuilder.build(from: place, ways: ways, walks: [walk])
        var cachedPlace = place
        cachedPlace.boundary = cached.boundary
        let restored = CityBuilder.build(from: cachedPlace, ways: cached.ways, walks: [walk])
        #expect(restored.grid == .world)
        #expect(restored.osmId == 123)
        #expect(restored.tiles == direct.tiles)
        #expect(restored.visited == direct.visited)
        #expect(!restored.visited.isEmpty)
        #expect(restored.roads == direct.roads)
        #expect(restored.roads?.map(\.kind) == [.road, .path])
        #expect(restored.tiles.count < City.hexes(inside: restored.shape(), grid: restored.grid).count)

        let noDriveway = CityBuilder.build(from: place, ways: ways.filter { $0.tags["service"] != "driveway" }, walks: [])
        let withDriveway = CityBuilder.build(from: place, ways: cached.ways, walks: [])
        #expect(noDriveway.tiles == withDriveway.tiles)
    }

    @Test func emptyCachedWaysKeepEveryTile() throws {
        let cached = try JSONDecoder().decode(CachedPlaceData.self, from: file(ways: []))
        let city = CityBuilder.build(from: place, ways: cached.ways, walks: [])
        #expect(city.tiles == City.hexes(inside: city.shape(), grid: city.grid))
        #expect(city.roads == [])
    }

    @Test func oldNearbyFilesStillDecode() throws {
        let encoded = try JSONEncoder().encode(place)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "osmId")
        let decoded = try JSONDecoder().decode(PlaceResult.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.osmId == nil)
        #expect(decoded.boundary == place.boundary)
        #expect(try JSONDecoder().decode(PlaceResult.self, from: encoded).osmId == 123)
    }

    @Test func nominatimOnlyKeepsRelationIds() throws {
        var result: [String: Any] = ["place_id": 5, "osm_id": 123, "osm_type": "relation", "name": "Test", "geojson": ["type": "Polygon", "coordinates": [outline]]]
        #expect(OSMClient.place(result)?.osmId == 123)
        result["osm_type"] = "way"
        #expect(OSMClient.place(result)?.osmId == nil)
        result.removeValue(forKey: "osm_type")
        #expect(OSMClient.place(result)?.osmId == nil)
    }

    @Test func malformedCacheIsRejected() throws {
        for json in [
            #"{"boundary":[],"ways":[]}"#,
            #"{"boundary":[[[[115,-33]]]],"ways":[]}"#,
            #"{"boundary":[[[[115,-33],[115,-34],[116,-34],[115,-33]]]],"ways":[{"highway":"path","points":[[91,115]]}]}"#,
        ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CachedPlaceData.self, from: Data(json.utf8)) }
        }
    }
}

@MainActor
@Suite(.serialized)
struct CachedPlaceHTTPTests {
    @Test func addDownloadsCachedFileWithTheAccountClient() async throws {
        let fixture = CachedPlaceTests()
        let file = try fixture.file(ways: fixture.ways)
        MockPlaceProtocol.respond = { request in
            if request.url?.path == "/api/action" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(request.httpMethod == "POST")
                // URLSession can turn httpBody into a stream before URLProtocol sees it.
                let data: Data
                if let body = request.httpBody { data = body }
                else if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    var body = Data()
                    while stream.hasBytesAvailable {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        if count <= 0 { break }
                        body.append(contentsOf: bytes.prefix(count))
                    }
                    data = body
                } else { data = Data() }
                let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(body["path"] as? String == "places:get")
                #expect((body["args"] as? [String: Int])?["osmId"] == 123)
                return Data(#"{"status":"success","value":{"url":"https://cache.test/place.json","fetchedAt":1000}}"#.utf8)
            }
            #expect(request.url?.absoluteString == "https://cache.test/place.json")
            return file
        }
        defer { MockPlaceProtocol.respond = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPlaceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var statuses: [String] = []
        let city = try await CityBuilder.build(from: fixture.place, walks: [], client: ConvexClient(token: "test-token", session: session)) {
            statuses.append($0)
        }
        let direct = CityBuilder.build(from: fixture.place, ways: fixture.ways, walks: [])
        #expect(city.tiles == direct.tiles)
        #expect(city.roads == direct.roads)
        #expect(statuses == ["Getting Test suburb ready…", "Laying out the tiles…"])
    }

    @Test(arguments: [false, true]) func cacheFailureFallsBackToOverpass(malformedFile: Bool) async throws {
        let fixture = CachedPlaceTests()
        let ways = fixture.ways
        MockPlaceProtocol.respond = { request in
            if request.url?.path == "/api/action" {
                if malformedFile {
                    return Data(#"{"status":"success","value":{"url":"https://cache.test/broken.json","fetchedAt":1000}}"#.utf8)
                }
                return Data(#"{"status":"error","errorMessage":"Cache unavailable"}"#.utf8)
            }
            if request.url?.host == "cache.test" { return Data("broken JSON".utf8) }
            #expect(request.url == OSMClient.overpassEndpoints.first)
            let elements: [[String: Any]] = ways.map { way in
                ["tags": way.tags, "geometry": way.points.map { ["lat": $0.lat, "lon": $0.lon] }]
            }
            return try JSONSerialization.data(withJSONObject: ["elements": elements])
        }
        defer { MockPlaceProtocol.respond = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPlaceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var statuses: [String] = []
        let city = try await CityBuilder.build(from: fixture.place, walks: [], client: ConvexClient(token: "test-token", session: session)) {
            statuses.append($0)
        }
        let direct = CityBuilder.build(from: fixture.place, ways: fixture.ways, walks: [])
        #expect(city.tiles == direct.tiles)
        #expect(city.roads == direct.roads)
        #expect(statuses == ["Getting Test suburb ready…", "Finding the streets and paths…", "Laying out the tiles…"])
    }

}

private nonisolated final class MockPlaceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
