import CoreLocation
import Foundation

nonisolated struct Coordinate: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(_ c: CLLocationCoordinate2D) {
        self.init(lat: c.latitude, lon: c.longitude)
    }

    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// Great-circle distance in metres.
    func distance(to other: Coordinate) -> Double {
        let rad = Double.pi / 180
        let dLat = (other.lat - lat) * rad
        let dLon = (other.lon - lon) * rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * rad) * cos(other.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * LocalProjection.earthRadius * asin(min(1, sqrt(a)))
    }

    func lerp(to other: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(lat: lat + (other.lat - lat) * t, lon: lon + (other.lon - lon) * t)
    }
}

nonisolated protocol GeoProjection: Sendable {
    func project(_ c: Coordinate) -> SIMD2<Double>
    func unproject(_ p: SIMD2<Double>) -> Coordinate
}

/// Spherical Web Mercator, scaled to ground metres at Busselton's latitude.
/// This has no local origin: a projected point means the same thing everywhere.
nonisolated struct WorldProjection: GeoProjection, Hashable, Sendable {
    static let earthRadius = 6_378_137.0
    static let referenceLatitude = -33.65
    static let scale = cos(referenceLatitude * .pi / 180)
    static let radius = earthRadius * scale

    func project(_ c: Coordinate) -> SIMD2<Double> {
        let lat = c.lat * .pi / 180
        return SIMD2(Self.radius * c.lon * .pi / 180, Self.radius * log(tan(.pi / 4 + lat / 2)))
    }

    func unproject(_ p: SIMD2<Double>) -> Coordinate {
        Coordinate(lat: (2 * atan(exp(p.y / Self.radius)) - .pi / 2) * 180 / .pi,
                   lon: p.x / Self.radius * 180 / .pi)
    }
}

/// Flat east/north metres around an origin, for local boundary and route geometry.
nonisolated struct LocalProjection: GeoProjection, Codable, Hashable, Sendable {
    static let earthRadius = 6_371_008.8

    let origin: Coordinate

    private var metresPerDegreeLat: Double { Self.earthRadius * .pi / 180 }
    private var metresPerDegreeLon: Double { metresPerDegreeLat * cos(origin.lat * .pi / 180) }

    func project(_ c: Coordinate) -> SIMD2<Double> {
        SIMD2((c.lon - origin.lon) * metresPerDegreeLon, (c.lat - origin.lat) * metresPerDegreeLat)
    }

    func unproject(_ p: SIMD2<Double>) -> Coordinate {
        Coordinate(lat: origin.lat + p.y / metresPerDegreeLat, lon: origin.lon + p.x / metresPerDegreeLon)
    }
}
