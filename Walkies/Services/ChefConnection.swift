import ChefKit
import Combine
import Foundation

/// Lets Chef (Seth's feedback board, `ChefKit`) talk to Convex through Walkies' own
/// client and sign-in, so there's no second Convex connection to keep signed in.
/// Chef wants live subscriptions for its lists; Walkies' client is plain HTTP, so
/// they're asked for again every few seconds while Chef's sheet is showing them.
nonisolated final class ChefConnection: ChefBackend {
    private let account: Account

    /// How often a list Chef is showing gets asked for again.
    static let pollEvery = Duration.seconds(4)

    init(account: Account) {
        self.account = account
    }

    func chefMutation<T: Decodable & Sendable>(_ name: String, args: [String: ChefValue]) async throws -> T {
        try await client().mutation(name, args)
    }

    func chefSubscribe<T: Decodable & Sendable>(_ name: String, args: [String: ChefValue], as type: T.Type)
        -> AnyPublisher<T, Error> {
        let subject = Box(PassthroughSubject<T, Error>())
        let task = Task { [weak self] in
            while !Task.isCancelled, let self {
                // A miss (no signal, signed out) just waits for the next go.
                if let value: T = try? await self.client().query(name, args) {
                    subject.value.send(value)
                }
                try? await Task.sleep(for: Self.pollEvery)
            }
        }
        return subject.value
            .handleEvents(receiveCancel: { task.cancel() })
            .eraseToAnyPublisher()
    }

    /// Signed in if there's a session, so Chef's calls are made as you.
    private func client() async -> ConvexClient {
        await account.client() ?? ConvexClient()
    }

    /// Only ever sent to from the polling task, one value at a time.
    private struct Box<V>: @unchecked Sendable {
        let value: V
        init(_ value: V) { self.value = value }
    }
}
