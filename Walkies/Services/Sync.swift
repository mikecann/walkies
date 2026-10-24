import Foundation
import Observation
import os

/// What's already been sent to the server, so each thing only goes up once.
nonisolated struct SyncState: Codable, Sendable {
    var uploadedWalks: Set<UUID> = []
    /// The change time of the copy of each city last sent.
    var uploadedPlaces: [UUID: Date] = [:]
    var uploadedSecrets: Set<String> = []
    /// Canonical JSON of the last ledger accepted by the server. Optional for old saves.
    var uploadedProgress: String?
    /// Places deleted on this phone that the server may still have. Optional for old saves.
    var deletedPlaces: Set<UUID>?
}

/// Keeps this phone and the account in step. The phone is the source of truth and
/// works offline; this pushes up anything new and pulls down anything missing
/// whenever there's a connection. Everything only ever grows, so there's nothing to
/// reconcile beyond adding, apart from places you delete, which are written down when
/// you delete them. A sync that fails halfway just carries on next time.
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var status = Status.idle
    private(set) var lastSynced: Date? {
        didSet { UserDefaults.standard.set(lastSynced, forKey: "lastSynced") }
    }
    /// Walks, cities and secrets on this phone that the server hasn't got yet.
    private(set) var waiting = 0

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let userId: () -> String?
    @ObservationIgnored private let makeClient: () async -> ConvexClient?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var state: SyncState
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var current: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var resetRevision = 0

    convenience init(model: AppModel, account: Account) {
        self.init(model: model, store: Store(), isSignedIn: { account.isSignedIn }, userId: { account.userId },
                  makeClient: { await account.client() })
    }

    init(model: AppModel, store: Store, isSignedIn: @escaping () -> Bool, userId: @escaping () -> String? = { nil },
         makeClient: @escaping () async -> ConvexClient?) {
        self.model = model
        self.store = store
        self.isSignedIn = isSignedIn
        self.userId = userId
        self.makeClient = makeClient
        state = store.loadSyncState()
        lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
        model.placesDeleted = { [weak self] in self?.deleted(places: $0) }
        model.walksChanged = { [weak self] in self?.changed(walks: $0) }
        countWaiting()
    }

    /// Reads what was synced again, for when the app started before the phone's first
    /// unlock and couldn't.
    func reload() {
        state = store.loadSyncState()
        lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
        countWaiting()
    }

    /// Syncs a moment from now. Several requests in a row become one sync.
    func schedule() {
        countWaiting()
        if running {
            pending = true
            return
        }
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard isSignedIn() else { return }
        if running {
            pending = true
            return
        }
        running = true
        let task = Task { await run() }
        current = task
        await task.value
    }

    private func run() async {
        let revision = resetRevision
        pending = false
        status = .syncing
        defer {
            running = false
            current = nil
            countWaiting()
            if pending {
                pending = false
                schedule()
            }
        }
        claimLocalData()
        guard let client = await makeClient() else {
            status = isSignedIn() ? .failed("Offline") : .idle
            return
        }
        do {
            // Refresh membership even when personal sync is temporarily unavailable.
            var personalError: Error?
            do {
                try check(revision)
                try await model.rebuildWorldGrid(using: client)
                try check(revision)
                await model.waitForHistory()
                try check(revision)
                try await push(client, revision: revision)
                try await pull(client, revision: revision)
            } catch { personalError = error }
            try await syncTeams(TeamsAPI(client: client), revision: revision)
            if let personalError { throw personalError }
            lastSynced = .now
            status = .idle
            // After the pull, so any place another phone already updated arrives first.
            model.refreshStreets()
            // A walk that's just gone up can start research for its place.
            model.refreshLore()
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
        // Places still waiting to be rebuilt show nothing on the map, so try again
        // soon rather than waiting for the next walk or launch.
        if model.worldGridResetPending, !pending {
            scheduled?.cancel()
            scheduled = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await sync()
            }
        }
    }

    /// Forgets what was sent, for signing out.
    func reset() {
        resetRevision += 1
        scheduled?.cancel()
        pending = false
        state = SyncState()
        lastSynced = nil
        status = .idle
        countWaiting()
    }

    /// Stops any sync in flight, then clears this phone, for signing out. A sync
    /// that was running can't put anything back afterwards.
    func wipe() async {
        reset()
        current?.cancel()
        await current?.value
        model.wipeLocalData()
        reset()
    }

    /// Places deleted on this phone, so the next push deletes them from the account too.
    private func deleted(places ids: [UUID]) {
        state.deletedPlaces = (state.deletedPlaces ?? []).union(ids)
        save()
        countWaiting()
    }

    /// How many times each walk has changed since the app opened, so an upload that was
    /// already on its way with the older copy isn't taken as the latest.
    private var walkEdits: [UUID: Int] = [:]

    /// Walks that changed after they went up (a place that added itself since counted
    /// their tiles), so they go up again. Saving a walk replaces its copy in the account.
    private func changed(walks ids: [UUID]) {
        for id in ids { walkEdits[id, default: 0] += 1 }
        state.uploadedWalks.subtract(ids)
        save()
        countWaiting()
    }

    /// This phone's data belongs to whoever it first synced for. Someone else signing in,
    /// say after a session ran out, starts from their own account instead. Anything the
    /// last account hadn't uploaded yet is lost here, but that's rare: their session
    /// would have to end with things still waiting.
    private func claimLocalData() {
        guard let user = userId() else { return }
        let owner = store.loadOwner()
        guard owner != user else { return }
        if owner != nil {
            model.wipeLocalData()
            state = SyncState()
            lastSynced = nil
        }
        store.save(owner: user)
    }

    /// Throws when a sign-out or reset has happened since the sync started.
    private func check(_ revision: Int) throws {
        guard isSignedIn(), resetRevision == revision, !Task.isCancelled else { throw CancellationError() }
    }

    // MARK: Push

    private func push(_ client: ConvexClient, revision: Int) async throws {
        // Only places deleted on purpose. A place that's just missing, say from a file
        // that wouldn't load, must never be deleted from the account.
        for id in state.deletedPlaces ?? [] {
            let _: Nothing = try await client.mutation("sync:deletePlace", DeletePlaceArgs(clientId: id.uuidString))
            try check(revision)
            state.deletedPlaces?.remove(id)
            state.uploadedPlaces[id] = nil
            save()
        }

        for city in model.cities {
            let changed = city.lastChanged
            if let sent = state.uploadedPlaces[city.id], sent >= changed { continue }
            let file = try await upload(JSONEncoder().encode(city), client)
            try check(revision)
            let _: Nothing = try await client.mutation("sync:savePlace", PlaceArgs(
                clientId: city.id.uuidString, name: city.name,
                createdAt: city.createdAt.ms, updatedAt: changed.ms, file: file
            ))
            try check(revision)
            state.uploadedPlaces[city.id] = changed
            save()
        }

        for walk in model.walks where !state.uploadedWalks.contains(walk.id) {
            guard let endedAt = walk.endedAt else { continue }
            let edit = walkEdits[walk.id]
            let file = try await upload(JSONEncoder().encode(walk), client)
            try check(revision)
            let _: Nothing = try await client.mutation("sync:saveWalk", WalkArgs(
                clientId: walk.id.uuidString, startedAt: walk.startedAt.ms, endedAt: endedAt.ms,
                distance: walk.distance, newTiles: Double(walk.newTiles), file: file
            ))
            try check(revision)
            // Credited again while this copy was on its way up: the next push sends the new one.
            guard walkEdits[walk.id] == edit else { continue }
            state.uploadedWalks.insert(walk.id)
            save()
        }

        let secrets = model.foundStickers.filter { !state.uploadedSecrets.contains($0.key) }
        if !secrets.isEmpty {
            let _: Nothing = try await client.mutation("sync:saveSecrets", SecretsArgs(secrets: secrets.map { SecretArgs(secretId: $0.key, foundAt: $0.value.ms) }))
            try check(revision)
            state.uploadedSecrets.formUnion(secrets.keys)
            save()
        }
        // A rejected ledger must never hold secret uploads behind it.
        let progress = try progressJSON(model.ledger)
        if state.uploadedProgress != progress {
            let _: Nothing = try await client.mutation("sync:saveProgress", ProgressArgs(ledger: progress))
            try check(revision)
            state.uploadedProgress = progress
            save()
        }
    }

    private func upload(_ data: Data, _ client: ConvexClient) async throws -> String {
        let url: String = try await client.mutation("sync:generateUploadUrl")
        guard let url = URL(string: url) else { throw ConvexError.server("Bad upload URL") }
        return try await client.upload(data, to: url)
    }

    // MARK: Pull

    /// Downloads are applied a batch at a time, so one bad file can't hold back the
    /// rest and a pull that's cut short keeps what it got. The first batch carries the
    /// ledger, so ownership is merged before any level menu is prepared.
    private static let batchSize = 25

    private func pull(_ client: ConvexClient, revision: Int) async throws {
        let snapshot: Snapshot = try await client.query("sync:snapshot", ["walkUrls": false])
        try check(revision)

        var progress = try snapshot.progress.map { try JSONDecoder().decode(Ledger.self, from: Data($0.utf8)) }
        var secrets = Dictionary(snapshot.secrets.map { ($0.secretId, Date(ms: $0.foundAt)) }, uniquingKeysWith: min)
        var batch = Batch()
        var failure: Error?
        // A place in the account that isn't here after all: it didn't download, or it
        // won't read on this version.
        var placesMissing = false

        func flush() async throws {
            try await apply(batch, progress: progress, secrets: secrets, revision: revision)
            batch = Batch()
            progress = nil
            secrets = [:]
        }

        for place in snapshot.places {
            guard let id = UUID(uuidString: place.clientId) else { continue }
            let remoteChanged = Date(ms: place.updatedAt)
            if let local = model.cities.first(where: { $0.id == id }) {
                if local.lastChanged >= remoteChanged { continue }
            } else if state.deletedPlaces?.contains(id) == true {
                continue
            }
            guard let url = place.url.flatMap(URL.init(string:)),
                  let city = try await fetch(City.self, from: url, client, revision: revision, failure: &failure) else {
                placesMissing = true
                continue
            }
            guard city.gridVersion == HexGrid.version else {
                failure = failure ?? ConvexError.server("The server still has places from the old grid.")
                continue
            }
            batch.cities.append(city)
            if batch.count >= Self.batchSize { try await flush() }
        }
        // Links only for the walks this phone hasn't got, so a sync doesn't sign one per walk.
        let have = Set(model.walks.map(\.id))
        let missing = snapshot.walks.map(\.clientId).filter { UUID(uuidString: $0).map { !have.contains($0) } ?? false }
        var links: [Snapshot.RemoteWalk] = []
        for start in stride(from: 0, to: missing.count, by: 100) {
            let chunk = Array(missing[start..<min(start + 100, missing.count)])
            links += try await client.query("sync:walkUrls", ["clientIds": chunk]) as [Snapshot.RemoteWalk]
            try check(revision)
        }
        for remote in links {
            guard let id = UUID(uuidString: remote.clientId), !have.contains(id),
                  let url = remote.url.flatMap(URL.init(string:)) else { continue }
            guard var walk = try await fetch(Walk.self, from: url, client, revision: revision, failure: &failure) else { continue }
            if walk.gridVersion != HexGrid.version {
                walk.resetGridCoverage()
                batch.rebuiltWalks.insert(walk.id)
            }
            batch.walks.append(walk)
            if batch.count >= Self.batchSize { try await flush() }
        }
        try await flush()
        // Anything that didn't download is tried again next sync.
        if let failure { throw failure }
        // Places add themselves only once every place in the account is here, so one
        // can't be a second copy of a place that just didn't come down this time. One
        // that won't read keeps them waiting too, until a later sync can read it.
        guard !placesMissing else { return }
        model.pulledAccount()
    }

    private struct Batch {
        var cities: [City] = []
        var walks: [Walk] = []
        var rebuiltWalks: Set<UUID> = []
        var count: Int { cities.count + walks.count }
    }

    private func apply(_ batch: Batch, progress: Ledger?, secrets: [String: Date], revision: Int) async throws {
        try check(revision)
        await model.addRemote(cities: batch.cities, walks: batch.walks, progress: progress, secrets: secrets)
        try check(revision)
        for city in batch.cities { state.uploadedPlaces[city.id] = max(state.uploadedPlaces[city.id] ?? .distantPast, city.lastChanged) }
        state.uploadedWalks.formUnion(batch.walks.map(\.id).filter { !batch.rebuiltWalks.contains($0) })
        // A retained server walk can still contain old hexes. Replace its blob on
        // the next push, after addRemote has rebuilt coverage from the raw GPS.
        if !batch.rebuiltWalks.isEmpty { pending = true }
        if let progress { state.uploadedProgress = try progressJSON(progress) }
        state.uploadedSecrets.formUnion(secrets.keys)
        save()
    }

    /// Nil when the file wouldn't download, which is tried again next sync, or wouldn't
    /// read, which is skipped so it can't stop every pull after it.
    private func fetch<T: Decodable>(_ type: T.Type, from url: URL, _ client: ConvexClient, revision: Int, failure: inout Error?) async throws -> T? {
        let data: Data
        do {
            data = try await client.download(url)
        } catch {
            try check(revision)
            failure = failure ?? error
            return nil
        }
        try check(revision)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("Skipping \(url.lastPathComponent) from the account, it won't read: \(error)")
            return nil
        }
    }

    private func syncTeams(_ api: TeamsAPI, revision: Int) async throws {
        guard isSignedIn(), resetRevision == revision else { throw CancellationError() }
        let membershipRevision = model.teamMembershipRevision
        let memberships = try await api.list()
        guard isSignedIn(), resetRevision == revision else { throw CancellationError() }
        model.acceptTeamList(memberships, revision: membershipRevision)
    }

    private func progressJSON(_ ledger: Ledger) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(ledger), as: UTF8.self)
    }

    private func save() {
        store.save(syncState: state)
    }

    private func countWaiting() {
        let deletes = state.deletedPlaces?.count ?? 0
        waiting = deletes
            + model.walks.filter { $0.endedAt != nil && !state.uploadedWalks.contains($0.id) }.count
            + model.cities.filter { (state.uploadedPlaces[$0.id] ?? .distantPast) < $0.lastChanged }.count
            + model.foundStickers.keys.filter { !state.uploadedSecrets.contains($0) }.count
            + ((try? progressJSON(model.ledger)) == state.uploadedProgress ? 0 : 1)
    }

    nonisolated private static let log = Logger(subsystem: "com.mikecann.walkies", category: "sync")
}

// MARK: Wire formats

private nonisolated struct PlaceArgs: Encodable {
    var gridVersion = HexGrid.version
    var clientId: String
    var name: String
    var createdAt: Double
    var updatedAt: Double
    var file: String
}

private nonisolated struct WalkArgs: Encodable {
    var gridVersion = HexGrid.version
    var clientId: String
    var startedAt: Double
    var endedAt: Double
    var distance: Double
    var newTiles: Double
    var file: String
}

private nonisolated struct DeletePlaceArgs: Encodable {
    var gridVersion = HexGrid.version
    var clientId: String
}

private nonisolated struct ProgressArgs: Encodable {
    var gridVersion = HexGrid.version
    var ledger: String
}

private nonisolated struct SecretsArgs: Encodable {
    var gridVersion = HexGrid.version
    var secrets: [SecretArgs]
}

private nonisolated struct SecretArgs: Encodable {
    var secretId: String
    var foundAt: Double
}

private nonisolated struct Snapshot: Decodable {
    struct RemoteWalk: Decodable { var clientId: String; var url: String? }
    struct RemotePlace: Decodable { var clientId: String; var updatedAt: Double; var url: String? }
    struct RemoteSecret: Decodable { var secretId: String; var foundAt: Double }

    var walks: [RemoteWalk]
    var places: [RemotePlace]
    var secrets: [RemoteSecret]
    var progress: String?
}

nonisolated extension Date {
    /// Milliseconds since 1970, how Convex likes its times.
    var ms: Double { (timeIntervalSince1970 * 1000).rounded(.down) }

    init(ms: Double) {
        self.init(timeIntervalSince1970: ms / 1000)
    }
}
