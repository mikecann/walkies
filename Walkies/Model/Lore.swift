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
    /// The suburb the story belongs to, as OpenStreetMap names it. The first batch
    /// (geographe.json) doesn't say; its pins decide.
    var suburb: String? = nil
}

/// The lore that ships with the app: the Busselton area so far.
nonisolated enum LoreLibrary {
    static let files = ["geographe", "busselton-area"]

    static let all: [LoreEntry] = files.flatMap(load)

    private static let byID = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }

    static func entry(id: String) -> LoreEntry? {
        byID[id]
    }

    /// Which secrets each place gets. A story about a spot belongs to the place that
    /// spot is in, so it's found where it happened, and waits there until you add
    /// that place. The few that aren't about one spot go to the first Busselton-area
    /// place you added.
    static func assign(
        _ entries: [LoreEntry] = all,
        to cities: [City],
        contains: (City, Coordinate) -> Bool
    ) -> [UUID: [LoreEntry]] {
        let home = cities.first { "\($0.name), \($0.detail)".contains("Busselton") }
        var out: [UUID: [LoreEntry]] = [:]
        for entry in entries {
            if let place = entry.place {
                if let owner = cities.first(where: { contains($0, place.coordinate) }) {
                    out[owner.id, default: []].append(entry)
                }
            } else if let home {
                out[home.id, default: []].append(entry)
            }
        }
        return out
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
    /// Leaves alone any tiles in `avoiding`, which already have a sticker.
    func placeStickers(_ entries: [LoreEntry], avoiding: Set<Hex> = []) -> [String: Hex] {
        let shape = shape()
        let streets = tiles.sorted { ($0.q, $0.r) < ($1.q, $1.r) }
        guard !streets.isEmpty else { return [:] }
        var placed: [String: Hex] = [:]
        var taken = avoiding
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
