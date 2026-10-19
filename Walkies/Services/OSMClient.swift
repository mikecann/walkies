import Foundation

nonisolated struct PlaceResult: Identifiable, Codable, Sendable {
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
        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: await overpass(query))
        return decoded.elements.compactMap { element in
            element.geometry.map { geometry in
                OSMWay(tags: element.tags ?? [:], points: geometry.map { Coordinate(lat: $0.lat, lon: $0.lon) })
            }
        }
    }

    /// Suburbs and localities with a boundary in the box. In Australia they're
    /// admin_level 9 (WA) or 10 (most other states). Overpass finds which ones, then
    /// Nominatim hands over their outlines in the same shape a search does.
    @concurrent
    static func placesNear(south: Double, west: Double, north: Double, east: Double) async throws -> [PlaceResult] {
        let query = """
        [out:json][timeout:60];
        relation["boundary"="administrative"]["admin_level"~"^(9|10)$"](\(south),\(west),\(north),\(east));
        out ids;
        """
        // Overpass can be slow or down, so don't wait long: there's a fallback.
        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: await overpass(query, timeout: 45))
        return try await lookup(relations: decoded.elements.compactMap(\.id))
    }

    /// The fallback for when Overpass is down: ask Nominatim which suburb each of
    /// these points is in, one a second as it asks, then fetch their outlines.
    @concurrent
    static func placesAt(_ points: [Coordinate]) async throws -> [PlaceResult] {
        var ids: [Int] = []
        for (n, point) in points.enumerated() {
            if n > 0 { try await Task.sleep(for: .seconds(1.1)) }
            var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
            components.queryItems = [
                URLQueryItem(name: "lat", value: String(point.lat)),
                URLQueryItem(name: "lon", value: String(point.lon)),
                // Suburb level. Any closer and it can answer with the suburb's
                // name pin rather than its boundary.
                URLQueryItem(name: "zoom", value: "12"),
                URLQueryItem(name: "format", value: "jsonv2"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response)
            guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  item["osm_type"] as? String == "relation", let id = item["osm_id"] as? Int, !ids.contains(id)
            else { continue }
            ids.append(id)
        }
        try await Task.sleep(for: .seconds(1.1))
        return try await lookup(relations: ids)
    }

    /// Outlines for these OSM boundary relations, from Nominatim.
    private static func lookup(relations ids: [Int]) async throws -> [PlaceResult] {
        var places: [PlaceResult] = []
        // Nominatim looks up at most 50 at a time, and asks for one request a second.
        for (n, start) in stride(from: 0, to: ids.count, by: 50).enumerated() {
            if n > 0 { try await Task.sleep(for: .seconds(1)) }
            var components = URLComponents(string: "https://nominatim.openstreetmap.org/lookup")!
            components.queryItems = [
                URLQueryItem(name: "osm_ids", value: ids[start..<min(start + 50, ids.count)].map { "R\($0)" }.joined(separator: ",")),
                URLQueryItem(name: "format", value: "jsonv2"),
                URLQueryItem(name: "polygon_geojson", value: "1"),
                URLQueryItem(name: "polygon_threshold", value: "0.0001"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response)
            let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            places += items.compactMap(place)
        }
        return places
    }

    /// Runs an Overpass query, trying each server in turn.
    private static func overpass(_ query: String, timeout: TimeInterval = 150) async throws -> Data {
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        var lastError: Error = OSMError.badResponse(0)
        for endpoint in overpassEndpoints {
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: timeout)
                request.httpMethod = "POST"
                request.httpBody = Data(body.utf8)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await URLSession.shared.data(for: request)
                try check(response)
                return data
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
        var id: Int?
        var tags: [String: String]?
        var geometry: [Point]?
    }
    var elements: [Element]
}
