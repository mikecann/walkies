import Foundation
import Observation

/// What's already been sent to the server, so each thing only goes up once.
nonisolated struct SyncState: Codable, Sendable {
    var uploadedWalks: Set<UUID> = []
    /// The change time of the copy of each city last sent.
    var uploadedPlaces: [UUID: Date] = [:]
    var uploadedSecrets: Set<String> = []
    /// Canonical JSON of the last ledger accepted by the server. Optional for old saves.
    var uploadedProgress: String?
}

/// Keeps this phone and the account in step. The phone is the source of truth and
/// works offline; this pushes up anything new and pulls down anything missing
/// whenever there's a connection. Everything only ever grows, so there's nothing to
/// reconcile beyond adding. A sync that fails halfway just carries on next time.
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
    @ObservationIgnored private let makeClient: () async -> ConvexClient?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var state: SyncState
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var resetRevision = 0

    convenience init(model: AppModel, account: Account) {
        self.init(model: model, store: Store(), isSignedIn: { account.isSignedIn }, makeClient: { await account.client() })
    }

    init(model: AppModel, store: Store, isSignedIn: @escaping () -> Bool, makeClient: @escaping () async -> ConvexClient?) {
        self.model = model
        self.store = store
        self.isSignedIn = isSignedIn
        self.makeClient = makeClient
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
        let revision = resetRevision
        running = true
        pending = false
        status = .syncing
        defer {
            running = false
            countWaiting()
            if pending {
                pending = false
                schedule()
            }
        }
        guard let client = await makeClient() else {
            status = isSignedIn() ? .failed("Offline") : .idle
            return
        }
        do {
            // One unavailable personal endpoint must not hold the crew queue behind it.
            var personalError: Error?
            do { try await push(client); try await pull(client) } catch { personalError = error }
            try await syncCrews(CrewsAPI(client: client), revision: revision)
            if let personalError { throw personalError }
            lastSynced = .now
            status = .idle
        } catch is CancellationError {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
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

    // MARK: Push

    private func push(_ client: ConvexClient) async throws {
        // Cities deleted on this phone.
        let here = Set(model.cities.map(\.id))
        for id in state.uploadedPlaces.keys where !here.contains(id) {
            let _: Nothing = try await client.mutation("sync:deletePlace", ["clientId": id.uuidString])
            state.uploadedPlaces[id] = nil
            save()
        }

        for city in model.cities {
            let changed = city.lastChanged
            if let sent = state.uploadedPlaces[city.id], sent >= changed { continue }
            let file = try await upload(JSONEncoder().encode(city), client)
            let _: Nothing = try await client.mutation("sync:savePlace", PlaceArgs(
                clientId: city.id.uuidString, name: city.name,
                createdAt: city.createdAt.ms, updatedAt: changed.ms, file: file
            ))
            state.uploadedPlaces[city.id] = changed
            save()
        }

        for walk in model.walks where !state.uploadedWalks.contains(walk.id) {
            guard let endedAt = walk.endedAt else { continue }
            let file = try await upload(JSONEncoder().encode(walk), client)
            let _: Nothing = try await client.mutation("sync:saveWalk", WalkArgs(
                clientId: walk.id.uuidString, startedAt: walk.startedAt.ms, endedAt: endedAt.ms,
                distance: walk.distance, newTiles: Double(walk.newTiles), file: file
            ))
            state.uploadedWalks.insert(walk.id)
            save()
        }

        let secrets = model.foundStickers.filter { !state.uploadedSecrets.contains($0.key) }
        if !secrets.isEmpty {
            let _: Nothing = try await client.mutation("sync:saveSecrets", [
                "secrets": secrets.map { SecretArgs(secretId: $0.key, foundAt: $0.value.ms) },
            ])
            state.uploadedSecrets.formUnion(secrets.keys)
            save()
        }
        // A rejected ledger must never hold secret uploads behind it.
        let progress = try progressJSON(model.ledger)
        if state.uploadedProgress != progress {
            let _: Nothing = try await client.mutation("sync:saveProgress", ["ledger": progress])
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

    private func pull(_ client: ConvexClient) async throws {
        let snapshot: Snapshot = try await client.query("sync:snapshot")

        // Download first, then apply one model transaction. No partial-history
        // reward menus are prepared while a fresh phone pulls its walks.
        let progress = try snapshot.progress.map { try JSONDecoder().decode(Ledger.self, from: Data($0.utf8)) }
        var cities: [City] = []
        for place in snapshot.places {
            guard let id = UUID(uuidString: place.clientId), let url = place.url.flatMap(URL.init(string:)) else { continue }
            let remoteChanged = Date(ms: place.updatedAt)
            if let local = model.cities.first(where: { $0.id == id }) {
                if local.lastChanged >= remoteChanged { continue }
            } else if state.uploadedPlaces[id] != nil {
                continue
            }
            cities.append(try JSONDecoder().decode(City.self, from: await client.download(url)))
        }
        let have = Set(model.walks.map(\.id))
        var walks: [Walk] = []
        for remote in snapshot.walks {
            guard let id = UUID(uuidString: remote.clientId), !have.contains(id),
                  let url = remote.url.flatMap(URL.init(string:)) else { continue }
            walks.append(try JSONDecoder().decode(Walk.self, from: await client.download(url)))
        }
        await model.addRemote(cities: cities, walks: walks, progress: progress, secrets: Dictionary(
            snapshot.secrets.map { ($0.secretId, Date(ms: $0.foundAt)) }, uniquingKeysWith: min
        ))
        for city in cities { state.uploadedPlaces[city.id] = max(state.uploadedPlaces[city.id] ?? .distantPast, city.lastChanged) }
        state.uploadedWalks.formUnion(walks.map(\.id))
        if let progress { state.uploadedProgress = try progressJSON(progress) }

        state.uploadedSecrets.formUnion(snapshot.secrets.map(\.secretId))
        save()
    }

    private func syncCrews(_ api: CrewsAPI, revision: Int) async throws {
        func checkSession() throws {
            guard isSignedIn(), resetRevision == revision else { throw CancellationError() }
        }
        try checkSession()
        await model.prepareCrewRoutes()
        let memberships = try await api.list()
        try checkSession()
        model.retainCrews(Set(memberships.map(\.crewId)))
        var failure: Error?
        for listing in memberships {
            let id = listing.crewId
            do {
                // Refresh preferences before sending any route. Snapshot replacement
                // removes cached trails on another phone's opt-out or departure.
                try checkSession()
                try await model.refreshCrew(id, api: api)
                if model.crews.first(where: { $0.id == id })?.pendingPlaces.isEmpty == false {
                    try await model.uploadCrewPlaces(id, api: api)
                    try checkSession()
                    try await model.refreshCrew(id, api: api)
                }
                guard let crew = model.crews.first(where: { $0.id == id }) else { continue }
                for batch in crew.pendingTiles {
                    do { try await api.tiles(id, batch: batch) }
                    catch {
                        try checkSession()
                        guard let coded = error as? ConvexError, ["TILE_LIMIT", "PLACE_BOUNDS_REQUIRED", "PLACE_NOT_FOUND", "INVALID_ARGUMENT"].contains(coded.code ?? "") else { throw error }
                        model.editCrew(id) { $0.syncMessage = error.localizedDescription; $0.since = nil }
                    }
                    try checkSession()
                    model.editCrew(id) { $0.pendingTiles.removeAll { $0.id == batch.id } }
                }
                for trail in crew.pendingTrails where crew.you?.sharing == .tilesAndTrail {
                    do {
                        let file: String
                        if let uploaded = trail.file { file = uploaded }
                        else {
                            file = try await api.upload(JSONEncoder().encode(trail.route))
                            try checkSession()
                            model.editCrew(id) { live in
                                if let i = live.pendingTrails.firstIndex(where: { $0.id == trail.id && $0.updatedAt == trail.updatedAt }) { live.pendingTrails[i].file = file }
                            }
                        }
                        try await api.trail(id, trail: trail, file: file)
                    }
                    catch {
                        try checkSession()
                        guard let coded = error as? ConvexError else { throw error }
                        if ["INVALID_UPLOAD", "FILE_NOT_FOUND"].contains(coded.code ?? "") {
                            model.editCrew(id) { live in
                                if let i = live.pendingTrails.firstIndex(where: { $0.id == trail.id && $0.updatedAt == trail.updatedAt }) { live.pendingTrails[i].file = nil }
                            }
                            throw error
                        }
                        guard ["TRAIL_LIMIT", "INVALID_ARGUMENT"].contains(coded.code ?? "") else { throw error }
                        model.editCrew(id) { $0.syncMessage = error.localizedDescription }
                    }
                    try checkSession()
                    model.editCrew(id) { $0.pendingTrails.removeAll { $0.id == trail.id && $0.updatedAt == trail.updatedAt } }
                }
                let entries = crew.pendingSecrets.sorted { $0.key < $1.key }
                for start in stride(from: 0, to: entries.count, by: 400) {
                    let batch = Dictionary(uniqueKeysWithValues: entries[start..<min(start + 400, entries.count)].map { ($0.key, $0.value) })
                    do { try await api.secrets(id, secrets: batch) }
                    catch {
                        try checkSession()
                        guard let coded = error as? ConvexError, ["SECRET_LIMIT", "INVALID_ARGUMENT"].contains(coded.code ?? "") else { throw error }
                        model.editCrew(id) { $0.syncMessage = error.localizedDescription }
                    }
                    try checkSession()
                    model.editCrew(id) { live in
                        for (secret, at) in batch where live.pendingSecrets[secret] == at { live.pendingSecrets[secret] = nil }
                    }
                }
                try checkSession()
                try await model.refreshCrew(id, api: api)
            } catch {
                try checkSession()
                if let error = error as? ConvexError, ["NOT_A_MEMBER", "CREW_NOT_FOUND", "MEMBER_REMOVED"].contains(error.code ?? "") {
                    model.retainCrews(Set(model.crews.map(\.id)).subtracting([id]))
                } else if let error = error as? ConvexError, error.code == "TRAIL_SHARING_DISABLED" {
                    model.editCrew(id) { $0.pendingTrails = []; $0.trails = []; $0.routeWork = [] }
                    try? await model.refreshCrew(id, api: api)
                } else { failure = error }
            }
        }
        if let failure { throw failure }
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
        waiting = model.walks.filter { $0.endedAt != nil && !state.uploadedWalks.contains($0.id) }.count
            + model.cities.filter { (state.uploadedPlaces[$0.id] ?? .distantPast) < $0.lastChanged }.count
            + model.foundStickers.keys.filter { !state.uploadedSecrets.contains($0) }.count
            + model.crews.reduce(0) { $0 + $1.waiting }
            + ((try? progressJSON(model.ledger)) == state.uploadedProgress ? 0 : 1)
    }
}

// MARK: Wire formats

private nonisolated struct PlaceArgs: Encodable {
    var clientId: String
    var name: String
    var createdAt: Double
    var updatedAt: Double
    var file: String
}

private nonisolated struct WalkArgs: Encodable {
    var clientId: String
    var startedAt: Double
    var endedAt: Double
    var distance: Double
    var newTiles: Double
    var file: String
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
