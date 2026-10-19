import Foundation

nonisolated struct PlaceResult: Identifiable, Sendable {
    var id: Int
    var name: String
    var detail: String
    /// What OSM calls it: suburb, town, city, municipality...
    var kind: String
    var boundary: Boundary
    /// Square metres.
    var area: Double
}

/// A street or path from Overpass, with its OSM tags (highway=residential etc).
nonisolated struct OSMWay: Sendable {
    var tags: [String: String]
    var points: [Coordinate]
}

nonisolated enum OSMError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "OpenStreetMap returned an error (\(code))."
        }
    }
}

/// Talks to the public OpenStreetMap services: Nominatim for place boundaries,
/// Overpass for the streets and paths inside them.
nonisolated enum OSMClient {
    static let userAgent = "Walkies/0.1 (personal iOS app)"

    static let overpassEndpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]

    /// Places matching the query that have a proper boundary. Nominatim asks for
    /// no search-as-you-type, so only call this when the user submits.
    @concurrent
    static func searchPlaces(_ query: String) async throws -> [PlaceResult] {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "polygon_geojson", value: "1"),
            URLQueryItem(name: "polygon_threshold", value: "0.0001"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.compactMap(place)
    }

    /// Lines for every street and path you could walk along inside the box.
    @concurrent
    static func walkableWays(south: Double, west: Double, north: Double, east: Double) async throws -> [OSMWay] {
        let excluded = "motorway|motorway_link|construction|proposed|raceway|bus_guideway|abandoned|razed"
        let query = """
        [out:json][timeout:120];
        way["highway"]["highway"!~"^(\(excluded))$"]["access"!~"^(private|no)$"]["foot"!~"^(private|no)$"]\
        (\(south),\(west),\(north),\(east));
        out geom;
        """
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

        var lastError: Error = OSMError.badResponse(0)
        for endpoint in overpassEndpoints {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 150)
                request.httpMethod = "POST"
                request.httpBody = Data(body.utf8)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await URLSession.shared.data(for: request)
                try check(response)
                let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
                return decoded.elements.compactMap { element in
                    element.geometry.map { geometry in
                        OSMWay(tags: element.tags ?? [:], points: geometry.map { Coordinate(lat: $0.lat, lon: $0.lon) })
                    }
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OSMError.badResponse(http.statusCode)
        }
    }

    private static func place(_ item: [String: Any]) -> PlaceResult? {
        guard let id = item["place_id"] as? Int,
              let geojson = item["geojson"] as? [String: Any],
              let type = geojson["type"] as? String,
              let coordinates = geojson["coordinates"]
        else { return nil }

        let polygons: [GeoPolygon]
        switch type {
        case "Polygon": polygons = [polygon(coordinates)].compactMap { $0 }
        case "MultiPolygon": polygons = (coordinates as? [Any])?.compactMap(polygon) ?? []
        default: return nil
        }
        guard !polygons.isEmpty else { return nil }

        var parts = (item["display_name"] as? String ?? "").components(separatedBy: ", ")
        let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parts.first ?? "Somewhere"
        if parts.first == name { parts.removeFirst() }

        let boundary = Boundary(polygons: polygons)
        let area = BoundaryShape(boundary, projection: LocalProjection(origin: boundary.centre)).area
        let kind = item["addresstype"] as? String ?? item["type"] as? String ?? "place"
        return PlaceResult(id: id, name: name, detail: parts.joined(separator: ", "), kind: kind, boundary: boundary, area: area)
    }

    /// GeoJSON polygon: rings of [lon, lat], the first is the outline and the rest are holes.
    private static func polygon(_ any: Any) -> GeoPolygon? {
        guard let rings = any as? [[[Double]]], let outer = rings.first else { return nil }
        func ring(_ points: [[Double]]) -> [Coordinate] {
            points.compactMap { $0.count >= 2 ? Coordinate(lat: $0[1], lon: $0[0]) : nil }
        }
        return GeoPolygon(outer: ring(outer), holes: rings.dropFirst().map(ring))
    }
}

private nonisolated struct OverpassResponse: Decodable {
    struct Element: Decodable {
        struct Point: Decodable {
            var lat: Double
            var lon: Double
        }
        var tags: [String: String]?
        var geometry: [Point]?
    }
    var elements: [Element]
}
