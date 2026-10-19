import Foundation

/// Everything the end-of-walk celebration needs: the order tiles and secrets turned
/// up along the route, how each place moved on, and a guess at how long until
/// you've finished. Worked out once, the moment the walk ends.
nonisolated struct WalkRecap: Identifiable, Sendable {
    /// A tile uncovered on the walk. `at` is how far along the route (0 to 1) you got to it.
    struct Reveal: Sendable {
        var place: UUID
        var hex: Hex
        var coordinate: Coordinate
        var at: Double
    }

    struct Secret: Sendable {
        var entry: LoreEntry
        var coordinate: Coordinate
        var at: Double
    }

    struct Place: Sendable, Identifiable {
        var id: UUID
        var name: String
        var before: Double
        var after: Double
        var newTiles: Int
        var tilesLeft: Int
    }

    struct Prediction: Sendable {
        var place: String
        /// Walks like your recent ones it'd take to uncover every tile left.
        var walks: Int
        /// How often you've been walking lately, if there's enough to go on.
        var walksPerWeek: Double?

        var weeks: Double? { walksPerWeek.map { Double(walks) / max($0, 0.1) } }
    }

    var id: UUID { walk.id }
    var walk: Walk
    /// The route, as evenly spaced points.
    var route: [Coordinate]
    var reveals: [Reveal]
    var secrets: [Secret]
    var places: [Place]
    var prediction: Prediction?
    /// More new tiles than any walk before it.
    var isBest: Bool
    /// The places this walk touched, as they were before it and after it.
    var before: [City]
    var after: [City]

    var newTiles: Int { reveals.count }

    /// - Parameters:
    ///   - cities: every place, as it is now the walk's over.
    ///   - fresh: the tiles this walk uncovered, per place.
    ///   - found: when each secret was found.
    ///   - history: your other finished walks.
    static func make(walk: Walk, cities: [City], fresh: [UUID: Set<Hex>], found: [String: Date], history: [Walk], now: Date = .now) -> WalkRecap {
        let route = CoverageTracer.samples(for: walk.points)
        let touched = cities.filter { !(fresh[$0.id] ?? []).isEmpty }

        // When the route first reaches each new tile.
        var reveals: [Reveal] = []
        for city in touched {
            let new = fresh[city.id] ?? []
            var firstSeen: [Hex: Int] = [:]
            for (i, point) in route.enumerated() {
                let hex = city.grid.hex(containing: point)
                if new.contains(hex), firstSeen[hex] == nil { firstSeen[hex] = i }
            }
            for hex in new {
                let at = firstSeen[hex].map { Double($0) / Double(max(route.count - 1, 1)) } ?? 1
                reveals.append(Reveal(place: city.id, hex: hex, coordinate: city.grid.projection.unproject(city.grid.centre(of: hex)), at: at))
            }
        }
        reveals.sort { ($0.at, $0.hex.q, $0.hex.r) < ($1.at, $1.hex.q, $1.hex.r) }

        // Secrets found during the walk, at the moment you reached their tile.
        let end = (walk.endedAt ?? now).addingTimeInterval(60)
        var secrets: [Secret] = []
        for city in touched {
            for (id, hex) in city.stickers ?? [:] {
                guard let date = found[id], date >= walk.startedAt, date <= end, let entry = LoreLibrary.entry(id: id) else { continue }
                let at = reveals.first { $0.place == city.id && $0.hex == hex }?.at ?? 1
                secrets.append(Secret(entry: entry, coordinate: city.grid.projection.unproject(city.grid.centre(of: hex)), at: at))
            }
        }
        secrets.sort { ($0.at, $0.entry.id) < ($1.at, $1.entry.id) }

        let before = touched.map { city -> City in
            var old = city
            old.visited.subtract(fresh[city.id] ?? [])
            return old
        }
        let places = zip(before, touched).map { old, now in
            Place(
                id: now.id, name: now.name,
                before: Double(old.visited.count) / Double(max(now.tiles.count, 1)), after: now.progress,
                newTiles: (fresh[now.id] ?? []).count, tilesLeft: now.tiles.count - now.visited.count
            )
        }.sorted { $0.newTiles > $1.newTiles }

        let finished = history.filter { $0.endedAt != nil && $0.id != walk.id }
        return WalkRecap(
            walk: walk, route: route, reveals: reveals, secrets: secrets, places: places,
            prediction: prediction(for: places.first, walk: walk, history: finished, now: now),
            isBest: !finished.isEmpty && reveals.count > (finished.map(\.newTiles).max() ?? 0),
            before: before, after: touched
        )
    }

    /// Tiles left over the new tiles your last ten real walks averaged, and how often
    /// you walk, from the last four weeks. Walks under 300 m (a dash to the letterbox)
    /// don't count towards either, unless that's all there is.
    static func prediction(for place: Place?, walk: Walk, history: [Walk], now: Date) -> Prediction? {
        guard let place, place.tilesLeft > 0 else { return nil }
        let all = (history + [walk]).sorted { $0.startedAt < $1.startedAt }
        let real = all.filter { $0.distance >= 300 }
        let recent = (real.isEmpty ? all : real).suffix(10)
        let average = Double(recent.map(\.newTiles).reduce(0, +)) / Double(recent.count)
        guard average >= 1 else { return nil }
        let walks = Int((Double(place.tilesLeft) / average).rounded(.up))

        let monthAgo = now.addingTimeInterval(-28 * 24 * 3600)
        let lately = (real.isEmpty ? all : real).filter { $0.startedAt >= monthAgo }
        var perWeek: Double?
        if lately.count >= 2, let first = lately.map(\.startedAt).min() {
            let span = max(now.timeIntervalSince(first), 7 * 24 * 3600)
            perWeek = Double(lately.count) / (span / (7 * 24 * 3600))
        }
        return Prediction(place: place.name, walks: walks, walksPerWeek: perWeek)
    }
}
