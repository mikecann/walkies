import Foundation

/// Places that add themselves (issue #2): the suburb you're in when you open the app,
/// and any suburb your walks go into. Only spots you've actually been count, never
/// where you've moved the map to. This is the deciding part, kept apart from the
/// network so it can be tested: for some spots, add a suburb whose outline is already
/// known, ask OpenStreetMap about one spot, or do nothing. OpenStreetMap asks apps to
/// go easy, so it's one spot at a time, a spot with no suburb at all (the sea, a
/// national park) isn't asked about again for a month, and a suburb whose streets
/// won't download waits longer each time. Saved as auto-places.json.
/// Keep this in step with AutoPlaces.kt.
nonisolated struct AutoPlaces: Codable, Sendable {
    /// Squares about 200 m across (`cellSize` degrees each way) where a lookup found no
    /// suburb at all, and when they can be asked about again.
    var missedUntil: [String: Date] = [:]
    /// Suburbs found that aren't yours: ones waiting to be added (their streets wouldn't
    /// download, say, or a walk only went along their edge), and ones you deleted, so
    /// the spots in them needn't be asked about again.
    var found: [PlaceResult] = []
    /// OSM ids of places you deleted on this phone. They don't add themselves again,
    /// though you can still add one by hand.
    var declined: Set<Int> = []
    /// Walks that ended before this never add places. Set the first time the app runs
    /// with this, so an update never adds places from walks done before it.
    var walksSince: Date?
    /// Walks since then whose spots have all been dealt with, by id, with when each
    /// ended so old ones can be forgotten. By id rather than up to a date, so an older
    /// walk that downloads after a newer one still gets looked at.
    var checkedWalks: [String: Date] = [:]
    /// After a lookup fails (offline, or OpenStreetMap's busy), no more until this.
    /// Saved, so iOS relaunching the app in the background doesn't skip the wait.
    var lookUpAgainAt: Date?
    /// Suburbs whose streets wouldn't download, by OSM id: how many times in a row, and
    /// when to try again.
    var buildFailures: [String: BuildFailure] = [:]

    struct BuildFailure: Codable, Equatable, Sendable {
        var count: Int
        var retryAt: Date
    }

    static let cellSize = 0.002
    static let missDays = 30.0
    /// A spot the fallback (Nominatim's reverse lookup, when Overpass is down) found
    /// nothing at is only ruled out for a day, since Overpass never answered.
    static let fallbackMissDays = 1.0
    /// Square metres. Smaller than this is a few streets rather than a suburb, so the
    /// next boundary up is used instead. The biggest is `CityBuilder.maxArea`.
    static let minArea = 100_000.0
    /// The admin_levels that can be a suburb. In England 10 is a parish, 8 a district or
    /// London borough, and 6 a city that runs itself (Bristol, which has no parishes) or
    /// a county, which the size limit rules out. Regions, states and countries never
    /// are, and nor are the neighbourhoods some countries map at 11.
    static let suburbLevels = 6...10
    /// In Australia, just the localities the neighbours use (9 in WA, 10 elsewhere), so
    /// a walk out along a jetty never adds a whole city council.
    static let australianLevels = 9...10
    /// Lookups in one go. The rest wait for the next time the app opens or a walk ends.
    static let lookupsPerRun = 10
    /// Metres. A fix vaguer than this when the app opens could be in the suburb next door.
    static let spotAccuracy = 50.0
    /// Metres. Where you are when the app opens only counts this far (or further, if
    /// the fix is vaguer) outside your places, so opening it at home near the border
    /// never adds the suburb over the road.
    static let spotMargin = 50.0
    /// Metres. A walk only adds a suburb it went this far into, and only spots this far
    /// out of your places are looked up, so GPS wobble either side of a street that's
    /// the border doesn't count.
    static let walkDepth = 30.0
    /// Metres. How much of a walk has to be `walkDepth` inside a suburb in one go, about
    /// five of its 10 m samples in a row, so one stray fix can't add it.
    static let walkStretch = 50.0
    /// Seconds after a failed lookup before the next.
    static let lookUpRetry = 5 * 60.0
    /// Seconds after a suburb's streets first won't download, doubling each time it
    /// fails again up to `buildRetryCap`, so a broken one doesn't rerun the heavy
    /// streets query every few minutes forever.
    static let buildRetry = 5 * 60.0
    static let buildRetryCap = 24 * 3600.0
    /// Walks that ended longer ago than this aren't looked at, and their ids are
    /// forgotten, so `checkedWalks` stays small. Plenty of time for one from another
    /// phone to download.
    static let walkDays = 30.0

    /// Where you were when the app opened, and how sure the GPS was (metres).
    struct Spot: Equatable, Sendable {
        var point: Coordinate
        var accuracy: Double
    }

    /// What a lookup at a spot came back with.
    struct Lookup: Equatable, Sendable {
        /// The suburb there, or nil if there isn't one.
        var place: PlaceResult?
        /// Overpass was down and Nominatim's reverse lookup answered instead, so finding
        /// nothing only rules the spot out for a day.
        var fallback = false
    }

    enum Next: Equatable, Sendable {
        /// Every spot is in one of your places, too close to one, or somewhere already
        /// ruled out.
        case nothing
        /// Nothing to do now, but some spots are waiting for OpenStreetMap or for a
        /// suburb's streets to be tried again, so these walks aren't done with yet.
        case later
        /// The suburb at a spot, from an outline that's already known.
        case add(PlaceResult)
        /// Ask OpenStreetMap which suburb this spot is in.
        case lookUp(Coordinate)
    }

    /// What to do about where you were when the app opened (`here`) and the samples
    /// along some walks (`tracks`), taken in order. Adds the first suburb whose outline
    /// is known (one found before, or a neighbour) and that you were in: `here` outside
    /// your places (`places`, world-projected) by more than the margin, or a walk
    /// properly into it. Otherwise asks about the first spot that needs it, or skips it
    /// when it's in a place you deleted, somewhere a lookup has already ruled out, or a
    /// hex already asked about this time round (`asked`).
    func next(here: Spot?, tracks: [[Coordinate]], places: [BoundaryShape], known: [PlaceResult],
              isYours: (PlaceResult) -> Bool, asked: Set<Hex> = [], now: Date) -> Next {
        let grid = HexGrid.world
        let outlines = (found + known).filter(Self.isSuburbSized).map { place in
            let use: Use = isYours(place) || place.osmId.map(declined.contains) == true ? .never
                : waitingToBuild(place, now: now) ? .later : .add
            return (place: place, shape: BoundaryShape(place.boundary, projection: grid.projection), use: use)
        }
        let canLookUp = lookUpAgainAt.map { now >= $0 } ?? true
        var waiting = false

        if let here {
            let p = grid.projection.project(here.point)
            let margin = Self.projected(max(here.accuracy, Self.spotMargin), at: here.point)
            if !places.contains(where: { $0.contains(p) || $0.isNear(p, within: margin) }) {
                if let outline = outlines.first(where: { $0.shape.contains(p) }) {
                    switch outline.use {
                    case .add: return .add(outline.place)
                    case .later: waiting = true
                    case .never: break
                    }
                } else if !asked.contains(grid.hex(containing: here.point)), !missed(at: here.point, now: now) {
                    if canLookUp { return .lookUp(here.point) }
                    waiting = true
                }
            }
        }

        for track in tracks {
            // Hexes of this walk already dealt with, and whether it went properly into
            // each known suburb, so each is only worked out once.
            var seen = Set<Hex>()
            var deep: [Int: Bool] = [:]
            for point in track {
                let hex = grid.hex(containing: point)
                guard !seen.contains(hex) else { continue }
                let p = grid.projection.project(point)
                if places.contains(where: { $0.contains(p) }) {
                    seen.insert(hex)
                    continue
                }
                // Close to the edge of one of yours. Another sample in this hex may be
                // further out, so it's not done with.
                if places.contains(where: { $0.isNear(p, within: Self.projected(Self.walkDepth, at: point)) }) { continue }
                seen.insert(hex)
                if let i = outlines.firstIndex(where: { $0.shape.contains(p) }) {
                    let outline = outlines[i]
                    guard outline.use == .add else {
                        if outline.use == .later { waiting = true }
                        continue
                    }
                    let went = deep[i] ?? Self.wentInto(outline.shape, along: track)
                    deep[i] = went
                    if went { return .add(outline.place) }
                    continue
                }
                if asked.contains(hex) || missed(at: point, now: now) { continue }
                if canLookUp { return .lookUp(point) }
                waiting = true
            }
        }
        return waiting ? .later : .nothing
    }

    /// What to do with a known suburb someone's been in.
    private enum Use {
        case add
        /// Its streets wouldn't download, and it's not time to try again yet.
        case later
        /// One of yours, or one you deleted.
        case never
    }

    /// Whether a walk went properly into a suburb: `walkStretch` metres of it in a row
    /// all at least `walkDepth` inside. Walking along a street that's the border, with
    /// the GPS wobbling either side, never does.
    static func wentInto(_ shape: BoundaryShape, along track: [Coordinate]) -> Bool {
        let projection = HexGrid.world.projection
        var stretch = 0.0
        var previous: Coordinate?
        for point in track {
            let p = projection.project(point)
            guard shape.contains(p), !shape.isNear(p, within: projected(walkDepth, at: point)) else {
                stretch = 0
                previous = nil
                continue
            }
            if let previous {
                let step = previous.distance(to: point)
                // Samples are 10 m apart along a stretch the GPS joined up. A bigger
                // jump is a gap in the walk, which starts the count again.
                stretch = step <= 2 * CoverageTracer.spacing ? stretch + step : 0
            }
            if stretch >= walkStretch { return true }
            previous = point
        }
        return false
    }

    /// A lookup at `point` came back with `lookup`.
    mutating func looked(at point: Coordinate, found lookup: Lookup, isYours: (PlaceResult) -> Bool, now: Date) {
        guard let place = lookup.place, Self.isSuburbSized(place) else {
            // No suburb here at all: the sea, or a national park.
            let days = lookup.fallback ? Self.fallbackMissDays : Self.missDays
            missedUntil[Self.cell(of: point)] = now.addingTimeInterval(days * 24 * 3600)
            return
        }
        // One of yours whose outline stops just short of the spot. Nothing's remembered,
        // so the suburb next door isn't ruled out around here; the run skips the hex.
        guard !isYours(place) else { return }
        // Even one you deleted, so its spots needn't be asked about again.
        if !found.contains(where: { Self.same($0, place) }) { found.append(place) }
    }

    /// A lookup failed: wait before the next.
    mutating func lookUpFailed(now: Date) {
        lookUpAgainAt = now.addingTimeInterval(Self.lookUpRetry)
    }

    /// This suburb's streets wouldn't download. It waits 5 minutes, then 10, 20 and so
    /// on up to a day, before it's tried again.
    mutating func failedToBuild(_ place: PlaceResult, now: Date) {
        let count = (buildFailures[Self.key(place)]?.count ?? 0) + 1
        let wait = min(Self.buildRetry * pow(2, Double(min(count, 20) - 1)), Self.buildRetryCap)
        buildFailures[Self.key(place)] = BuildFailure(count: count, retryAt: now.addingTimeInterval(wait))
    }

    func waitingToBuild(_ place: PlaceResult, now: Date) -> Bool {
        buildFailures[Self.key(place)].map { now < $0.retryAt } ?? false
    }

    mutating func added(_ place: PlaceResult) {
        found.removeAll { Self.same($0, place) }
        buildFailures[Self.key(place)] = nil
    }

    /// Kept in `found`, if it's there, so its spots aren't asked about again.
    mutating func decline(osmId: Int) {
        declined.insert(osmId)
    }

    /// The walks whose spots still need checking: ended since `walksSince`, in the last
    /// `walkDays`, and not done with yet.
    func due(_ walks: [Walk], now: Date) -> [Walk] {
        let since = max(walksSince ?? .distantFuture, now.addingTimeInterval(-Self.walkDays * 24 * 3600))
        return walks.filter { walk in
            guard let ended = walk.endedAt else { return false }
            return ended > since && checkedWalks[walk.id.uuidString] == nil
        }
    }

    mutating func checked(_ walks: [Walk]) {
        for walk in walks { checkedWalks[walk.id.uuidString] = walk.endedAt }
    }

    func missed(at point: Coordinate, now: Date) -> Bool {
        guard let until = missedUntil[Self.cell(of: point)] else { return false }
        return now < until
    }

    /// Drops what's run out, so the file doesn't grow forever: misses that can be
    /// asked about again, walks too old to look at, and suburbs whose streets haven't
    /// been tried for a month (which start again from 5 minutes).
    mutating func tidy(now: Date) {
        missedUntil = missedUntil.filter { now < $0.value }
        let old = now.addingTimeInterval(-Self.walkDays * 24 * 3600)
        checkedWalks = checkedWalks.filter { $0.value > old }
        buildFailures = buildFailures.filter { $0.value.retryAt > old }
    }

    static func cell(of point: Coordinate) -> String {
        "\(Int((point.lat / cellSize).rounded(.down))),\(Int((point.lon / cellSize).rounded(.down)))"
    }

    static func isSuburbSized(_ place: PlaceResult) -> Bool {
        place.area >= minArea && place.area <= CityBuilder.maxArea
    }

    /// Metres on the ground as world-projected units at this spot. The world projection
    /// is Mercator, true to scale only at Busselton's latitude.
    static func projected(_ metres: Double, at point: Coordinate) -> Double {
        metres * WorldProjection.scale / max(0.01, cos(point.lat * .pi / 180))
    }

    private static func same(_ a: PlaceResult, _ b: PlaceResult) -> Bool {
        if let x = a.osmId, let y = b.osmId { return x == y }
        return a.name == b.name && a.detail == b.detail
    }

    private static func key(_ place: PlaceResult) -> String {
        place.osmId.map(String.init) ?? "\(place.name), \(place.detail)"
    }

    /// A boundary a spot is in, as Overpass's is_in describes it.
    struct Relation: Sendable {
        var id: Int
        var adminLevel: String?
        /// The ISO 3166-1 code, which only a country has.
        var country: String?
    }

    /// The boundaries a spot is in that could be its suburb, smallest first: the
    /// highest admin_level allowed in that country, ties by relation id. `country` is
    /// for when there's no country boundary among them (Nominatim's answer, say).
    static func suburbCandidates(_ relations: [Relation], country: String? = nil) -> [Int] {
        let australia = country?.uppercased() == "AU" || relations.contains { $0.country?.uppercased() == "AU" }
        let levels = australia ? australianLevels : suburbLevels
        var levelled: [(id: Int, level: Int)] = []
        for relation in relations {
            guard let level = relation.adminLevel.flatMap({ Int($0) }), levels.contains(level) else { continue }
            levelled.append((relation.id, level))
        }
        levelled.sort { $0.level != $1.level ? $0.level > $1.level : $0.id < $1.id }
        var seen = Set<Int>()
        return levelled.map(\.id).filter { seen.insert($0).inserted }
    }

    /// The suburb from these outlines, in `order` (smallest first): the first that's a
    /// sensible size, so a tiny one gives way to the next one up.
    static func pick(_ places: [PlaceResult], order: [Int]) -> PlaceResult? {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return places
            .filter { $0.osmId.flatMap { rank[$0] } != nil }
            .sorted { rank[$0.osmId!]! < rank[$1.osmId!]! }
            .first(where: isSuburbSized)
    }
}

nonisolated extension AutoPlaces {
    /// Anything missing (from a file an earlier build wrote, say) starts empty, rather
    /// than the whole file failing to read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        missedUntil = try c.decodeIfPresent([String: Date].self, forKey: .missedUntil) ?? [:]
        found = try c.decodeIfPresent([PlaceResult].self, forKey: .found) ?? []
        declined = try c.decodeIfPresent(Set<Int>.self, forKey: .declined) ?? []
        walksSince = try c.decodeIfPresent(Date.self, forKey: .walksSince)
        checkedWalks = try c.decodeIfPresent([String: Date].self, forKey: .checkedWalks) ?? [:]
        lookUpAgainAt = try c.decodeIfPresent(Date.self, forKey: .lookUpAgainAt)
        buildFailures = try c.decodeIfPresent([String: BuildFailure].self, forKey: .buildFailures) ?? [:]
    }
}
