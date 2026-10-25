import Foundation

/// Secrets the server has written for your places that have no bundled ones
/// (shared/lore-api.md): what `lore:forPlace` last said about each, saved in
/// server-lore.json with their sticker art in server-stickers/, so they work offline.
/// The app asks again now and then (`due`), and a new version replaces the last lot.
nonisolated struct ServerLore: Codable, Sendable, Equatable {
    /// Where the server's got to with a place.
    enum Status: String, Codable, Sendable {
        /// The app ships this place's secrets, so it never asks again.
        case bundled
        /// Nobody's walked there since the server started researching.
        case notStarted = "none"
        /// Waiting for a free slot, or for a spending cap to reset.
        case queued
        /// A run's going. It takes 5 to 15 minutes.
        case researching
        case ready
        /// Done, but there wasn't much to find.
        case quiet
        /// The run broke. The server has another go after a day.
        case failed

        /// Still being looked into, so the map says so.
        var isLooking: Bool { self == .queued || self == .researching }

        /// A status from a newer server that this version doesn't know is like "none".
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .notStarted
        }
    }

    /// What `lore:forPlace` answers.
    struct Answer: Decodable, Sendable {
        var status: Status
        var version: Int
        var entries: [Entry]
    }

    /// One secret as the server sends it: the same JSON as a bundled LoreEntry, plus
    /// where its sticker art is (`stickerUrl`, null if the drawing failed).
    struct Entry: Decodable, Sendable {
        var entry: LoreEntry
        var stickerURL: URL?

        private enum CodingKeys: String, CodingKey { case stickerUrl }

        init(entry: LoreEntry, stickerURL: URL? = nil) {
            self.entry = entry
            self.stickerURL = stickerURL
        }

        init(from decoder: Decoder) throws {
            entry = try LoreEntry(from: decoder)
            stickerURL = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(URL.self, forKey: .stickerUrl)
        }
    }

    /// The last answer for one place.
    struct Place: Codable, Sendable, Equatable {
        var osmId: Int
        var status: Status
        var version: Int
        var entries: [LoreEntry]
        /// Where each secret's art is on the server, by id. Missing when it hasn't got any.
        var stickerURLs: [String: URL] = [:]
        /// When the server was last asked about it, whether it answered or not.
        var askedAt: Date
    }

    var places: [Place] = []
    /// Secrets the server has taken down since you found them, so they stay in your book.
    var kept: [LoreEntry] = []
    /// Where each saved sticker came from, by secret id, so art is only downloaded
    /// again when it's changed.
    var savedStickers: [String: URL] = [:]

    func place(_ osmId: Int) -> Place? {
        places.first { $0.osmId == osmId }
    }

    /// Whether the server's answered about this place yet, rather than not been asked or not answered.
    func hasAnswered(_ osmId: Int) -> Bool {
        (place(osmId)?.version ?? -1) >= 0
    }

    /// The live secrets by OpenStreetMap relation, for LoreLibrary.assign.
    var byPlace: [Int: [LoreEntry]] {
        Dictionary(places.map { ($0.osmId, $0.entries) }) { first, _ in first }
    }

    /// Every secret here: each place's, then the kept ones.
    var all: [LoreEntry] {
        var seen = Set<String>()
        return (places.flatMap(\.entries) + kept).filter { seen.insert($0.id).inserted }
    }

    func entry(id: String) -> LoreEntry? {
        places.lazy.flatMap(\.entries).first { $0.id == id } ?? kept.first { $0.id == id }
    }

    /// Which of your places could have secrets from the server: ones with an
    /// OpenStreetMap relation that the app has no bundled secrets for, and that the
    /// server hasn't said it has.
    func askable(_ cities: [City]) -> [Int] {
        var seen = Set<Int>()
        return cities.compactMap(\.osmId).filter { osmId in
            !LoreLibrary.bundledOsmIds.contains(osmId) && place(osmId)?.status != .bundled && seen.insert(osmId).inserted
        }
    }

    /// How long after asking about a place to ask again, by what it said.
    static func wait(after status: Status) -> TimeInterval {
        switch status {
        // A run takes 5 to 15 minutes, so every couple of minutes while the app's open.
        case .queued, .researching: 110
        // A walk there can start a run, and sync asks again after each one.
        case .notStarted, .failed: 10 * 60
        // These only change when Mike approves or hides one.
        case .ready, .quiet: 60 * 60
        case .bundled: .infinity
        }
    }

    /// Of `osmIds`, the ones due another ask at `now`.
    func due(_ osmIds: [Int], now: Date) -> [Int] {
        osmIds.filter { osmId in
            guard let place = place(osmId) else { return true }
            return now.timeIntervalSince(place.askedAt) >= Self.wait(after: place.status)
        }
    }

    /// What taking in an answer changed.
    struct Change: Equatable, Sendable {
        /// Secrets that weren't here before, for the note on the map.
        var arrived: [LoreEntry] = []
        /// The place has just turned out to have nothing much to find.
        var quiet = false
        /// Sticker art to download, by secret id.
        var stickers: [String: URL] = [:]
    }

    /// Takes in what the server said about a place. The same version as last time
    /// changes nothing but the status. A new one replaces the place's secrets, since
    /// one can be taken down later; one taken down after you'd found it (in `found`)
    /// is kept, so it stays in your book.
    mutating func take(_ answer: Answer, for osmId: Int, at now: Date, found: [String: Date]) -> Change {
        var change = Change()
        let old = place(osmId)
        var place = old ?? Place(osmId: osmId, status: answer.status, version: -1, entries: [], askedAt: now)
        change.quiet = answer.status == .quiet && answer.entries.isEmpty && old?.status != .quiet
        place.status = answer.status
        place.askedAt = now
        if answer.version != place.version {
            let entries = answer.entries.map(\.entry)
            let live = Set(entries.map(\.id))
            let had = Set(place.entries.map(\.id))
            change.arrived = entries.filter { !had.contains($0.id) }
            for gone in place.entries where !live.contains(gone.id) && found[gone.id] != nil && !kept.contains(where: { $0.id == gone.id }) {
                kept.append(gone)
            }
            // Back again (approved after being hidden, say): live, not kept.
            kept.removeAll { live.contains($0.id) }
            place.version = answer.version
            place.entries = entries
            place.stickerURLs = Dictionary(answer.entries.compactMap { e in e.stickerURL.map { (e.entry.id, $0) } }) { first, _ in first }
        }
        if let i = places.firstIndex(where: { $0.osmId == osmId }) { places[i] = place } else { places.append(place) }
        // Also any that didn't download last time.
        change.stickers = place.stickerURLs.filter { savedStickers[$0.key] != $0.value }
        return change
    }

    /// The server didn't answer, so wait the usual time before asking about it again.
    mutating func noteAsked(_ osmId: Int, at now: Date) {
        if let i = places.firstIndex(where: { $0.osmId == osmId }) {
            places[i].askedAt = now
        } else {
            places.append(Place(osmId: osmId, status: .notStarted, version: -1, entries: [], askedAt: now))
        }
    }

    /// Forgets places that aren't yours any more (deleted, say), keeping any of their
    /// secrets you'd found. Returns the secrets whose saved art can go.
    mutating func keepOnly(_ osmIds: Set<Int>, found: [String: Date]) -> [String] {
        for place in places where !osmIds.contains(place.osmId) {
            for entry in place.entries where found[entry.id] != nil && !kept.contains(where: { $0.id == entry.id }) {
                kept.append(entry)
            }
        }
        places.removeAll { !osmIds.contains($0.osmId) }
        let wanted = Set(all.map(\.id))
        let unused = savedStickers.keys.filter { !wanted.contains($0) }.sorted()
        for id in unused { savedStickers[id] = nil }
        return unused
    }

    /// A server secret's sticker file in `folder`. The id comes from the server, so
    /// it's made safe as a file name first.
    static func stickerFile(for id: String, in folder: URL) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? "sticker"
        return folder.appending(path: "\(safe).png")
    }

    /// Whether downloaded art really is a PNG, rather than an error page.
    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}
