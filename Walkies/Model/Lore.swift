import Foundation
import os
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
    /// One or two photos from Wikimedia Commons, shown under the story.
    var photos: [Photo]? = nil

    /// A freely licensed photo, bundled as an asset, with the credit its licence asks for.
    struct Photo: Codable, Hashable, Sendable {
        var asset: String
        var caption: String
        /// Who took it and the licence, e.g. "Jane Smith · CC BY-SA 4.0".
        var credit: String
        /// Its page on Commons.
        var source: String
    }
}

/// The lore the app knows about: what ships with it (the Busselton area so far), and
/// what the server has written for your other places (ServerLore), which the app hands
/// over with `useServer`.
nonisolated enum LoreLibrary {
    static let files = ["geographe", "busselton-area"]

    /// The secrets that ship with the app.
    static let bundled: [LoreEntry] = files.flatMap(load)

    /// The OpenStreetMap relations the bundled secrets cover, from bundled-places.json
    /// (the server's `bundledOsmIds`, which a server test keeps it matching). These
    /// places never ask the server for secrets.
    static let bundledOsmIds: Set<Int> = {
        struct File: Decodable {
            struct Place: Decodable { var osmId: Int }
            var places: [Place]
        }
        guard let url = Bundle.main.url(forResource: "bundled-places", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return Set(file.places.map(\.osmId))
    }()

    private static let byID = Dictionary(bundled.map { ($0.id, $0) }) { first, _ in first }

    /// The server's secrets, as last handed over. Behind a lock because the views,
    /// notifications and background work all read it.
    private struct Server: Sendable {
        var all: [LoreEntry] = []
        var byID: [String: LoreEntry] = [:]
        var stickers: URL?
        var revision = 0
    }
    private static let server = OSAllocatedUnfairLock(initialState: Server())

    /// Every secret: the bundled ones, then the server's.
    static var all: [LoreEntry] { bundled + server.withLock { $0.all } }

    static func entry(id: String) -> LoreEntry? {
        byID[id] ?? server.withLock { $0.byID[id] }
    }

    static func bundledEntry(id: String) -> LoreEntry? {
        byID[id]
    }

    /// Goes up whenever the server's secrets or their art change, so cached images go too.
    static var serverRevision: Int { server.withLock { $0.revision } }

    /// Takes the server's secrets for the views and notifications, with the folder their
    /// sticker art is saved in.
    static func useServer(_ lore: ServerLore, stickers: URL) {
        let entries = lore.all.filter { byID[$0.id] == nil }
        server.withLock {
            $0.all = entries
            $0.byID = Dictionary(entries.map { ($0.id, $0) }) { first, _ in first }
            $0.stickers = stickers
            $0.revision += 1
        }
    }

    /// A server secret's sticker art, if it's been downloaded. Bundled ones are assets.
    static func serverSticker(id: String) -> URL? {
        guard let folder = server.withLock({ $0.stickers }) else { return nil }
        let file = ServerLore.stickerFile(for: id, in: folder)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Which secrets each place gets. A story about a spot belongs to the place that
    /// spot is in, so it's found where it happened, and waits there until you add
    /// that place. One about a whole suburb goes to that suburb, scattered over its
    /// streets. The few from the first batch that aren't about anywhere in particular
    /// go to the first Busselton-area place you added. The server's secrets (`server`,
    /// by OpenStreetMap relation) go to the place with that relation, pins and all.
    static func assign(
        _ entries: [LoreEntry] = bundled,
        server: [Int: [LoreEntry]] = [:],
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
            } else if let suburb = entry.suburb {
                if let owner = cities.first(where: { $0.name.caseInsensitiveCompare(suburb) == .orderedSame }) {
                    out[owner.id, default: []].append(entry)
                }
            } else if let home {
                out[home.id, default: []].append(entry)
            }
        }
        // By relation, not by name: two suburbs can share a name, and the server's
        // pins have already been moved inside the one it researched.
        for (osmId, entries) in server.sorted(by: { $0.key < $1.key }) {
            guard let owner = cities.first(where: { $0.osmId == osmId }) else { continue }
            out[owner.id, default: []].append(contentsOf: entries)
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
