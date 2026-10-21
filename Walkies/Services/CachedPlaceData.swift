import Foundation

/// The compact shared OSM file in Convex storage. Boundary coordinates use
/// GeoJSON's [lon, lat]; street points use [lat, lon]. Validate before using either
/// so a malformed cache falls back to the direct OSM fetch rather than losing tiles.
nonisolated struct CachedPlaceData: Decodable, Sendable {
    var boundary: Boundary
    var ways: [OSMWay]
    /// The street cache's version (WalkableRule.version), from places:get rather than
    /// the file. Nil from a server older than version 2, whose ways weren't filtered.
    var version: Int?
    /// What a place built from these streets records as City.streetsVersion.
    var streetsVersion: Int? { version.flatMap { $0 >= WalkableRule.version ? WalkableRule.version : nil } }

    private enum CodingKeys: String, CodingKey { case boundary, ways }
    private struct Way: Decodable {
        var highway: String
        var footway: String?
        var service: String?
        var access: String?
        var foot: String?
        var points: [[Double]]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let polygons = try container.decode([[[[Double]]]].self, forKey: .boundary)
        let streets = try container.decode([Way].self, forKey: .ways)
        func invalid() -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid cached OSM geometry"))
        }
        func coordinate(_ pair: [Double], geoJSON: Bool) throws -> Coordinate {
            guard pair.count == 2 else { throw invalid() }
            let lat = pair[geoJSON ? 1 : 0], lon = pair[geoJSON ? 0 : 1]
            guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { throw invalid() }
            return Coordinate(lat: lat, lon: lon)
        }
        guard !polygons.isEmpty else { throw invalid() }
        boundary = Boundary(polygons: try polygons.map { rings in
            guard let outer = rings.first, rings.allSatisfy({ $0.count >= 4 }) else { throw invalid() }
            return GeoPolygon(
                outer: try outer.map { try coordinate($0, geoJSON: true) },
                holes: try rings.dropFirst().map { try $0.map { try coordinate($0, geoJSON: true) } }
            )
        })
        ways = try streets.map { way in
            guard !way.highway.isEmpty else { throw invalid() }
            var tags = ["highway": way.highway]
            tags["footway"] = way.footway
            tags["service"] = way.service
            tags["access"] = way.access
            tags["foot"] = way.foot
            return OSMWay(tags: tags, points: try way.points.map { try coordinate($0, geoJSON: false) })
        }
    }

    static func fetch(osmId: Int, client: ConvexClient) async throws -> CachedPlaceData {
        struct File: Decodable { var url: URL; var fetchedAt: Double; var version: Int? }
        let file: File = try await client.action("places:get", ["osmId": osmId])
        var data = try JSONDecoder().decode(CachedPlaceData.self, from: await client.download(file.url))
        data.version = file.version
        return data
    }
}
