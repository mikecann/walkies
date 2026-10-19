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
    @ObservationIgnored private let account: Account
    @ObservationIgnored private let store = Store()
    @ObservationIgnored private var state: SyncState
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false

    init(model: AppModel, account: Account) {
        self.model = model
        self.account = account
        state = store.loadSyncState()
        lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
        countWaiting()
    }

    /// Syncs a moment from now. Several requests in a row become one sync.
    func schedule() {
        countWaiting()
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard !running, account.isSignedIn else { return }
        running = true
        status = .syncing
        defer {
            running = false
            countWaiting()
        }
        guard let client = await account.client() else {
            status = account.isSignedIn ? .failed("Offline") : .idle
            return
        }
        do {
            try await push(client)
            try await pull(client)
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
        scheduled?.cancel()
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

        let progress = try progressJSON(model.ledger)
        if state.uploadedProgress != progress {
            let _: Nothing = try await client.mutation("sync:saveProgress", ["ledger": progress])
            state.uploadedProgress = progress
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
    }

    private func upload(_ data: Data, _ client: ConvexClient) async throws -> String {
        let url: String = try await client.mutation("sync:generateUploadUrl")
        guard let url = URL(string: url) else { throw ConvexError.server("Bad upload URL") }
        return try await client.upload(data, to: url)
    }

    // MARK: Pull

    private func pull(_ client: ConvexClient) async throws {
        let snapshot: Snapshot = try await client.query("sync:snapshot")

        // Cities first, so the walks that follow are replayed over them.
        for place in snapshot.places {
            guard let id = UUID(uuidString: place.clientId), let url = place.url.flatMap(URL.init(string:)) else { continue }
            let remoteChanged = Date(ms: place.updatedAt)
            if let local = model.cities.first(where: { $0.id == id }) {
                if local.lastChanged >= remoteChanged { continue }
            } else if state.uploadedPlaces[id] != nil {
                continue // Deleted on this phone since it was sent.
            }
            let city = try JSONDecoder().decode(City.self, from: await client.download(url))
            model.addRemote(city)
            state.uploadedPlaces[id] = max(state.uploadedPlaces[id] ?? .distantPast, city.lastChanged)
            save()
        }

        let have = Set(model.walks.map(\.id))
        for remote in snapshot.walks {
            guard let id = UUID(uuidString: remote.clientId), !have.contains(id) else { continue }
            guard let url = remote.url.flatMap(URL.init(string:)) else { continue }
            let walk = try JSONDecoder().decode(Walk.self, from: await client.download(url))
            model.addRemote(walk)
            state.uploadedWalks.insert(id)
            save()
        }

        if let json = snapshot.progress {
            let remote = try JSONDecoder().decode(Ledger.self, from: Data(json.utf8))
            model.addRemoteProgress(remote)
            state.uploadedProgress = try progressJSON(remote)
        }

        model.addRemoteSecrets(Dictionary(
            snapshot.secrets.map { ($0.secretId, Date(ms: $0.foundAt)) },
            uniquingKeysWith: min
        ))
        state.uploadedSecrets.formUnion(snapshot.secrets.map(\.secretId))
        save()
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
