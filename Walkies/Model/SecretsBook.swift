import Foundation

/// The book works from the whole library, even for places you haven't added yet.
/// Distances belong to areas, never to individual mystery stickers.
nonisolated enum SecretsBook {
    enum Sort: String, CaseIterable, Identifiable {
        case nearest, alphabetical, mostFound

        var id: String { rawValue }
        var title: String {
            switch self {
            case .nearest: "Nearest first"
            case .alphabetical: "A to Z"
            case .mostFound: "Most found"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, found, notFound

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .found: "Found"
            case .notFound: "Not found yet"
            }
        }
    }

    struct Area: Identifiable, Sendable {
        var name: String
        /// Only entries matching the filter. Counts and distance still cover the whole area.
        var entries: [LoreEntry]
        var found: Int
        var total: Int
        var distance: Double?
        var isAdded: Bool

        var id: String { name }
        var progress: Double { total == 0 ? 0 : Double(found) / Double(total) }
    }

    static func sections(
        entries: [LoreEntry], found: [String: Date], location: Coordinate?, places: [City],
        selectedCity: City? = nil, sort: Sort = .nearest, filter: Filter = .all
    ) -> [Area] {
        let origin = location ?? selectedCity?.boundary.centre
        let grouped = Dictionary(grouping: entries) { $0.suburb ?? "Around Busselton" }
        let areas = grouped.compactMap { name, entries -> Area? in
            let visible = entries.filter { entry in
                switch filter {
                case .all: true
                case .found: found[entry.id] != nil
                case .notFound: found[entry.id] == nil
                }
            }
            guard !visible.isEmpty else { return nil }
            let distance = origin.flatMap { origin in
                entries.compactMap { $0.place?.coordinate.distance(to: origin) }.min()
            }
            return Area(
                name: name,
                entries: visible.sorted { a, b in
                    // Keep the newest finds first, as in the original book.
                    switch (found[a.id], found[b.id]) {
                    case let (x?, y?) where x != y: return x > y
                    case (.some, nil): return true
                    case (nil, .some): return false
                    default: return a.title == b.title ? a.id < b.id : a.title < b.title
                    }
                },
                found: entries.filter { found[$0.id] != nil }.count,
                total: entries.count,
                distance: distance,
                isAdded: places.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            )
        }
        return areas.sorted { a, b in
            switch sort {
            case .nearest:
                // With no fix or selected place, every distance is nil and names decide.
                switch (a.distance, b.distance) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            case .mostFound:
                if a.found != b.found { return a.found > b.found }
            case .alphabetical:
                break
            }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
    }
}
