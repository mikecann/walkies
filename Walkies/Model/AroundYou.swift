import Foundation

/// The suburbs around where you are, for the server to research ahead of you
/// (`lore:prepare`), so their secrets are waiting by the time you walk over the border.
/// The suburb you're in and the ones next to it, from your places and the neighbours
/// list (`AppModel.nearby`); the server checks each for itself.
nonisolated enum AroundYou {
    /// A neighbour counts as next door if its box comes this close (metres) to the box
    /// of the suburb you're in.
    static let nextDoor = 500.0
    /// The most `lore:prepare` takes at once.
    static let most = 12
    /// The same suburbs aren't asked about again for this long.
    static let again: TimeInterval = 30 * 60

    typealias Box = (south: Double, west: Double, north: Double, east: Double)

    /// The suburb you're in first, then its neighbours, without ones that ship their own
    /// secrets. Empty if you're in none we know of.
    static func suburbs(at point: Coordinate, places: [City], nearby: [PlaceResult], bundled: Set<Int> = LoreLibrary.bundledOsmIds) -> [Int] {
        let projected = HexGrid.world.projection.project(point)
        let inside: (Boundary) -> Bool = { BoundaryShape($0, projection: HexGrid.world.projection).contains(projected) }
        let here: (osmId: Int?, box: Box)
        if let city = places.first(where: { contains($0.boundary.bounds, point) && inside($0.boundary) }) {
            here = (city.osmId, city.boundary.bounds)
        } else if let place = nearby.first(where: { contains($0.boundary.bounds, point) && inside($0.boundary) }) {
            here = (place.osmId, place.boundary.bounds)
        } else {
            return []
        }
        let reach = grown(here.box, by: nextDoor)
        var ids: [Int] = []
        if let osmId = here.osmId { ids.append(osmId) }
        let around = (places.map { ($0.osmId, $0.boundary.bounds) } + nearby.map { ($0.osmId, $0.boundary.bounds) })
            .compactMap { osmId, box in osmId.map { ($0, box) } }
            .filter { overlaps($0.1, reach) }
            .map(\.0)
            .sorted()
        for osmId in around where !ids.contains(osmId) { ids.append(osmId) }
        return Array(ids.filter { !bundled.contains($0) }.prefix(most))
    }

    /// Whether to ask: these suburbs aren't the ones last asked about, or it's been a while.
    static func due(_ ids: [Int], last: (ids: [Int], at: Date)?, now: Date) -> Bool {
        guard !ids.isEmpty else { return false }
        guard let last else { return true }
        return Set(ids) != Set(last.ids) || now.timeIntervalSince(last.at) >= again
    }

    private static func contains(_ box: Box, _ p: Coordinate) -> Bool {
        p.lat >= box.south && p.lat <= box.north && p.lon >= box.west && p.lon <= box.east
    }

    private static func overlaps(_ a: Box, _ b: Box) -> Bool {
        a.north >= b.south && a.south <= b.north && a.east >= b.west && a.west <= b.east
    }

    private static func grown(_ box: Box, by metres: Double) -> Box {
        let dLat = metres / 111_320
        let dLon = dLat / max(0.1, cos((box.south + box.north) / 2 * .pi / 180))
        return (box.south - dLat, box.west - dLon, box.north + dLat, box.east + dLon)
    }
}
