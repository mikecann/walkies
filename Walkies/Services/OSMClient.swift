import Foundation

nonisolated struct PlaceResult: Identifiable, Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var detail: String
    /// What OSM calls it: suburb, town, city, municipality...
    var kind: String
    var boundary: Boundary
    /// Square metres.
    var area: Double
    /// OSM relation id, distinct from Nominatim's place_id. Nil in older nearby.json files.
    var osmId: Int? = nil
}

/// A street or path from Overpass, with its OSM tags (highway=residential etc).
nonisolated struct OSMWay: Sendable {
    var tags: [String: String]
    var points: [Coordinate]
}

/// Which OSM ways you could walk along. Keep this in step with isWalkable in
/// convex/placeData.ts, which filters the shared street cache, and OSMClient.kt.
/// Motorways and private ways are out. Trunk and primary roads, and anything signed
/// 80 km/h or more, are out unless they have a footpath or are open to walkers.
/// Footpaths mapped alongside them are separate ways and stay in as normal.
nonisolated enum WalkableRule {
    /// Places built from streets filtered by this rule. Matches the street cache's
    /// version in convex/places.ts; a place built with less has its tiles redone once.
    static let version = 2

    static let excludedHighways: Set = ["motorway", "motorway_link", "construction", "proposed", "raceway", "bus_guideway", "abandoned", "razed"]
    private static let busyRoads: Set = ["trunk", "trunk_link", "primary", "primary_link"]
    private static let pathTypes: Set = ["footway", "path", "cycleway", "pedestrian", "steps", "bridleway", "corridor"]
    private static let sidewalkValues: Set = ["both", "left", "right", "yes", "separate"]

    static func isWalkable(_ tags: [String: String]) -> Bool {
        guard let highway = tags["highway"], !excludedHighways.contains(highway) else { return false }
        if ["private", "no"].contains(tags["access"] ?? "") || ["private", "no"].contains(tags["foot"] ?? "") { return false }
        let sidewalk = sidewalkValues.contains(tags["sidewalk"] ?? "")
            || ["sidewalk:left", "sidewalk:right", "sidewalk:both"].contains { ["yes", "separate"].contains(tags[$0] ?? "") }
        let foot = tags["foot"]
        let walkersWelcome = foot == "yes" || foot == "designated"
        if busyRoads.contains(highway), !sidewalk, !walkersWelcome, foot != "permissive", tags["footway"] != "sidewalk" { return false }
        if !pathTypes.contains(highway), let limit = speedLimit(tags["maxspeed"]), limit >= 80, !sidewalk, !walkersWelcome { return false }
        return true
    }

    /// km/h from an OSM maxspeed ("80", "80 km/h", "50 mph"), or nil for "none", "AU:urban" and the like.
    static func speedLimit(_ maxspeed: String?) -> Double? {
        guard let text = maxspeed?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        switch text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "km/h", "kmh", "kph": return value
        case "mph": return value * 1.609344
        default: return nil
        }
    }
}

nonisolated enum OSMError: LocalizedError {
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "OpenStreetMap returned an error (\(code))."
        }
    }
}

/// One request at a time to one of OpenStreetMap's services, each starting at least
/// `spacing` after the one before. Everything the app asks Nominatim or Overpass goes
/// through these, so the suburbs next door, places adding themselves and adding one
/// by hand can't pile up on them at once. OSMClient.kt has the same.
actor OSMLane {
    private let spacing: Duration
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lastStart: ContinuousClock.Instant?

    init(spacing: Duration) {
        self.spacing = spacing
    }

    /// Runs `request` once it's this one's turn.
    func run<T: Sendable>(_ request: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        // Handing straight to the next in line keeps it busy, so nothing can jump the queue.
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        if let lastStart, spacing > .zero { try await Task.sleep(until: lastStart + spacing, clock: .continuous) }
        lastStart = .now
        return try await request()
    }
}

/// Talks to the public OpenStreetMap services: Nominatim for place boundaries,
/// Overpass for the streets and paths inside them.
nonisolated enum OSMClient {
    static let userAgent = "Walkies/0.1 (personal iOS app)"

    /// Nominatim asks for no more than one request a second.
    static let nominatim = OSMLane(spacing: .seconds(1.1))
    /// Overpass asks apps not to run queries side by side, and the streets query is heavy.
    static let overpassLane = OSMLane(spacing: .zero)

    static let overpassEndpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
    ]

    /// Places matching the query that have a proper boundary. Nominatim asks for
    /// no search-as-you-type, so only call this when the user submits.
    @concurrent
    static func searchPlaces(_ query: String, session: URLSession = .shared) async throws -> [PlaceResult] {
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
        let data = try await fetch(request, session: session)
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return items.compactMap(place)
    }

    /// Lines for every street and path you could walk along inside the box.
    @concurrent
    static func walkableWays(south: Double, west: Double, north: Double, east: Double, session: URLSession = .shared) async throws -> [OSMWay] {
        let excluded = WalkableRule.excludedHighways.sorted().joined(separator: "|")
        // `out geom` brings every tag, which WalkableRule needs (sidewalk, foot, maxspeed).
        let query = """
        [out:json][timeout:120];
        way["highway"]["highway"!~"^(\(excluded))$"]["access"!~"^(private|no)$"]["foot"!~"^(private|no)$"]\
        (\(south),\(west),\(north),\(east));
        out geom;
        """
        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: await overpass(query, session: session))
        return decoded.elements.compactMap { element in
            guard let geometry = element.geometry, WalkableRule.isWalkable(element.tags ?? [:]) else { return nil }
            return OSMWay(tags: element.tags ?? [:], points: geometry.map { Coordinate(lat: $0.lat, lon: $0.lon) })
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
    static func placesAt(_ points: [Coordinate], session: URLSession = .shared) async throws -> [PlaceResult] {
        var ids: [Int] = []
        for point in points {
            guard let item = try await reverse(point, session: session),
                  item["osm_type"] as? String == "relation", let id = item["osm_id"] as? Int, !ids.contains(id)
            else { continue }
            ids.append(id)
        }
        return try await lookup(relations: ids, session: session)
    }

    /// The suburb a spot is in, for places that add themselves, or none if there isn't
    /// one to add (the sea, a national park, somewhere only a county covers). Overpass
    /// says which boundaries the spot is in and AutoPlaces picks the smallest that's a
    /// suburb, town or village; one Nominatim lookup brings their outlines. If Overpass
    /// is down, Nominatim's own idea of the suburb there will do, as for the neighbours,
    /// as long as it passes the same rule.
    @concurrent
    static func suburb(at point: Coordinate, session: URLSession = .shared) async throws -> AutoPlaces.Lookup {
        let candidates: [Int]
        do {
            let query = """
            [out:json][timeout:25];
            is_in(\(point.lat),\(point.lon))->.here;
            relation(pivot.here)["boundary"="administrative"]["admin_level"];
            out tags;
            """
            let decoded = try JSONDecoder().decode(OverpassResponse.self, from: await overpass(query, timeout: 45, session: session))
            // A timed-out query still comes back 200, with a remark and nothing in it,
            // which mustn't count as there being no suburb here.
            if decoded.remark != nil { throw OSMError.badResponse(200) }
            candidates = AutoPlaces.suburbCandidates(decoded.elements.compactMap { element in
                element.id.map {
                    AutoPlaces.Relation(id: $0, adminLevel: element.tags?["admin_level"],
                                        country: element.tags?["ISO3166-1"] ?? element.tags?["ISO3166-1:alpha2"])
                }
            })
        } catch {
            return try await fallbackSuburb(at: point, session: session)
        }
        guard !candidates.isEmpty else { return AutoPlaces.Lookup(place: nil) }
        return AutoPlaces.Lookup(place: AutoPlaces.pick(try await lookup(relations: candidates, session: session), order: candidates))
    }

    /// With Overpass down: Nominatim's reverse lookup at a few zooms stands in for is_in
    /// (`AutoPlaces.fallbackCandidates`), then one lookup brings the outlines, and the
    /// suburb has to pass the same rule (so in Australia only a locality, never the
    /// council).
    private static func fallbackSuburb(at point: Coordinate, session: URLSession) async throws -> AutoPlaces.Lookup {
        let candidates = try await AutoPlaces.fallbackCandidates { zoom in
            reverseAnswer(try await reverse(point, zoom: zoom, details: true, session: session) ?? [:])
        }
        guard !candidates.isEmpty else { return AutoPlaces.Lookup(place: nil, fallback: true) }
        return AutoPlaces.Lookup(place: AutoPlaces.pick(try await lookup(relations: candidates, session: session), order: candidates), fallback: true)
    }

    /// The boundary a detailed reverse lookup answered with, if it's one rather than a
    /// town's name pin, with its admin_level, and the country the spot's in.
    static func reverseAnswer(_ item: [String: Any]) -> AutoPlaces.ReverseAnswer {
        var relation: AutoPlaces.Relation?
        if item["osm_type"] as? String == "relation", let id = item["osm_id"] as? Int {
            relation = AutoPlaces.Relation(id: id, adminLevel: (item["extratags"] as? [String: Any])?["admin_level"] as? String)
        }
        return AutoPlaces.ReverseAnswer(relation: relation, country: (item["address"] as? [String: Any])?["country_code"] as? String)
    }

    /// Nominatim's reverse lookup. `zoom` 12 is suburb level: any closer and it can answer
    /// with the suburb's name pin rather than its boundary. `details` brings the
    /// boundary's tags (its admin_level) and the country it's in.
    private static func reverse(_ point: Coordinate, zoom: Int = 12, details: Bool = false, session: URLSession) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(point.lat)),
            URLQueryItem(name: "lon", value: String(point.lon)),
            URLQueryItem(name: "zoom", value: String(zoom)),
            URLQueryItem(name: "format", value: "jsonv2"),
        ] + (details ? [URLQueryItem(name: "extratags", value: "1"), URLQueryItem(name: "addressdetails", value: "1")] : [])
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await fetch(request, session: session)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Outlines for these OSM boundary relations, from Nominatim.
    private static func lookup(relations ids: [Int], session: URLSession = .shared) async throws -> [PlaceResult] {
        var places: [PlaceResult] = []
        // Nominatim looks up at most 50 at a time.
        for start in stride(from: 0, to: ids.count, by: 50) {
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
            let data = try await fetch(request, session: session)
            let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            places += items.compactMap(place)
        }
        return places
    }

    /// One Nominatim request, in turn with every other.
    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Data {
        try await nominatim.run {
            let (data, response) = try await session.data(for: request)
            try check(response)
            return data
        }
    }

    /// Runs an Overpass query, trying each server in turn, one query at a time.
    private static func overpass(_ query: String, timeout: TimeInterval = 150, session: URLSession = .shared) async throws -> Data {
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return try await overpassLane.run {
            var lastError: Error = OSMError.badResponse(0)
            for endpoint in overpassEndpoints {
                do {
                    var request = URLRequest(url: endpoint, timeoutInterval: timeout)
                    request.httpMethod = "POST"
                    request.httpBody = Data(body.utf8)
                    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    let (data, response) = try await session.data(for: request)
                    try check(response)
                    return data
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OSMError.badResponse(http.statusCode)
        }
    }

    static func place(_ item: [String: Any]) -> PlaceResult? {
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
        return PlaceResult(id: id, name: name, detail: parts.joined(separator: ", "), kind: kind, boundary: boundary, area: area,
                           osmId: item["osm_type"] as? String == "relation" ? item["osm_id"] as? Int : nil)
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
    /// Set when Overpass gave up partway, say on a timeout.
    var remark: String?
}
