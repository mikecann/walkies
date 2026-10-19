import Foundation
import simd

/// A bit of local history or a story about a place, found by walking to it.
/// Each one is a sticker for the sticker book.
nonisolated struct LoreEntry: Codable, Identifiable, Hashable, Sendable {
    struct Place: Codable, Hashable, Sendable {
        var name: String
        var lat: Double
        var lon: Double

        var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
    }

    var id: String
    var title: String
    var body: String
    /// history, first-nations, nature, the-sea, odd-records or modern-life.
    var category: String
    /// Where the story happened, when it's about one spot.
    var place: Place?
    /// What the sticker shows, for making the art.
    var sticker: String
    var sources: [String]
}

/// The lore that ships with the app.
nonisolated enum LoreLibrary {
    /// Only the Busselton area has lore so far.
    static func entries(for city: City) -> [LoreEntry] {
        let area = "\(city.name), \(city.detail)"
        guard area.contains("Busselton") else { return [] }
        return busselton
    }

    static let busselton: [LoreEntry] = load("geographe")

    static func entry(id: String) -> LoreEntry? {
        busselton.first { $0.id == id }
    }

    private static func load(_ name: String) -> [LoreEntry] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? JSONDecoder().decode([LoreEntry].self, from: data)) ?? []
    }
}

nonisolated extension City {
    /// Hides each sticker under a tile. Stories about a spot in the suburb go under the
    /// nearest street tile to it; the rest are spread out, as far apart as possible, on
    /// tiles you haven't walked yet. Worked out once and saved, so stickers never move.
    func placeStickers(_ entries: [LoreEntry]) -> [String: Hex] {
        let shape = shape()
        let streets = tiles.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        guard !streets.isEmpty else { return [:] }
        var placed: [String: Hex] = [:]
        var taken = Set<Hex>()
        let ordered = entries.sorted { $0.id < $1.id }

        for entry in ordered {
            guard let place = entry.place else { continue }
            let spot = grid.projection.project(place.coordinate)
            guard shape.contains(spot) else { continue }
            let nearest = streets
                .filter { !taken.contains($0) }
                .min { simd_distance(grid.centre(of: $0), spot) < simd_distance(grid.centre(of: $1), spot) }
            if let nearest, simd_distance(grid.centre(of: nearest), spot) < 300 {
                placed[entry.id] = nearest
                taken.insert(nearest)
            }
        }

        let open = streets.filter { !visited.contains($0) }
        guard !open.isEmpty else { return placed }
        for entry in ordered where placed[entry.id] == nil {
            // Try a handful of tiles, picked the same way every time for this entry,
            // and keep the one furthest from every other sticker.
            var rng = SplitMix64(seed: Self.stableHash(entry.id))
            var best: Hex?
            var bestGap = -1.0
            for _ in 0..<40 {
                let candidate = open[Int(rng.next() % UInt64(open.count))]
                guard !taken.contains(candidate) else { continue }
                let centre = grid.centre(of: candidate)
                let gap = taken.map { simd_distance(centre, grid.centre(of: $0)) }.min() ?? .infinity
                if gap > bestGap {
                    best = candidate
                    bestGap = gap
                }
            }
            if let best {
                placed[entry.id] = best
                taken.insert(best)
            }
        }
        return placed
    }

    /// FNV-1a. Swift's own hashValue changes every launch, so it can't seed anything saved.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }
}
