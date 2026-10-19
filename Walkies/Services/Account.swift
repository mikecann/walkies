import AuthenticationServices
import Foundation
import Observation
import Security
import UIKit

/// Session tokens from Convex Auth, plus who they belong to.
nonisolated struct Session: Codable, Sendable {
    var accessToken: String
    /// Milliseconds since 1970, as Convex Auth sends them.
    var accessTokenExpiresAt: Double
    var refreshToken: String
    var refreshTokenExpiresAt: Double
    var userId: String
    var name: String?
    var email: String?
}

/// Signing in with Apple or Google through Convex Auth v2. Their sign-in pages run
/// in a secure sheet that ends on the deployment's own site, which the app is
/// linked to, so the sheet hands the one-time code straight back. The session
/// lives in the Keychain.
@Observable
final class Account {
    enum Provider: String {
        case apple = "Apple"
        case google = "Google"
    }

    private(set) var session: Session?

    var isSignedIn: Bool { session != nil }
    /// The name to show for whoever's signed in.
    var displayName: String? { session?.name ?? session?.email }
    var email: String? { session?.email }

    @ObservationIgnored private let sheet = SignInSheet()
    @ObservationIgnored private var refreshing: Task<Session?, Never>?

    init() {
        session = Keychain.load()
    }

    // MARK: Signing in

    func signIn(with provider: Provider) async throws {
        let returnTo = Backend.site.appending(path: "app/signed-in")
        let start: StartResult = try await ConvexClient().mutation(
            "auth:startSignInWith\(provider.rawValue)", ["redirectTo": returnTo.absoluteString]
        )
        guard let page = URL(string: start.redirect) else { throw SignInError.failed }

        let landed = try await sheet.open(page, returningTo: returnTo)
        let query = URLComponents(url: landed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "convexAuthError" })?.value {
            throw error == "access_denied" ? SignInError.cancelled : SignInError.failed
        }
        guard let code = query.first(where: { $0.name == "convexAuthCode" })?.value else { throw SignInError.failed }

        let result: CompleteResult = try await ConvexClient().mutation(
            "auth:completeSignInWith\(provider.rawValue)", ["code": code, "state": start.state]
        )
        guard result.status == "complete", var tokens = result.tokens else { throw SignInError.failed }

        // Who this is, for Settings. Not essential, so a hiccup here doesn't stop sign-in.
        if let me: Me = try? await ConvexClient(token: tokens.accessToken).query("users:me") {
            tokens.name = me.name
            tokens.email = me.email
        }
        save(tokens)
    }

    // MARK: Using the session

    /// A client with a fresh access token, refreshing it first if it's about to run out.
    /// Nil when signed out or the session has ended.
    func client() async -> ConvexClient? {
        guard let session else { return nil }
        let now = Date.now.timeIntervalSince1970 * 1000
        if session.accessTokenExpiresAt - now > 60_000 {
            return ConvexClient(token: session.accessToken)
        }
        return await refreshedSession().map { ConvexClient(token: $0.accessToken) }
    }

    /// One refresh at a time: refresh tokens rotate, so two at once would trip over each other.
    private func refreshedSession() async -> Session? {
        if let refreshing { return await refreshing.value }
        guard let current = session else { return nil }
        let task = Task { () -> Session? in
            do {
                let result: RefreshResult = try await ConvexClient().mutation(
                    "auth:refreshSession", ["refreshToken": current.refreshToken]
                )
                guard result.kind == "rotated", var tokens = result.tokens else {
                    clear()
                    return nil
                }
                tokens.name = current.name
                tokens.email = current.email
                save(tokens)
                return tokens
            } catch {
                // Offline or the server's having a moment: keep the session and try later.
                return nil
            }
        }
        refreshing = task
        let refreshed = await task.value
        refreshing = nil
        return refreshed
    }

    func signOut() async {
        if let refreshToken = session?.refreshToken {
            let _: Nothing? = try? await ConvexClient().mutation("auth:signOut", ["refreshToken": refreshToken])
        }
        clear()
    }

    private func save(_ tokens: Session) {
        session = tokens
        Keychain.save(tokens)
    }

    private func clear() {
        session = nil
        Keychain.delete()
    }
}

nonisolated enum SignInError: LocalizedError {
    case cancelled
    case failed

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .failed: "Something went wrong signing in. Try again."
        }
    }
}

// MARK: Wire formats

private nonisolated struct StartResult: Decodable {
    var redirect: String
    var state: String
}

private nonisolated struct CompleteResult: Decodable {
    var status: String
    var tokens: Session?
}

private nonisolated struct RefreshResult: Decodable {
    var kind: String
    var tokens: Session?
}

private nonisolated struct Me: Decodable {
    var name: String?
    var email: String?
}

// MARK: The sign-in sheet

/// Runs Apple's or Google's sign-in page in a secure sheet that shares Safari's
/// sign-ins, and catches the moment it lands back on Walkies' own site.
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func open(_ page: URL, returningTo returnTo: URL) async throws -> URL {
        guard let host = returnTo.host() else { throw SignInError.failed }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: page,
                callback: .https(host: host, path: returnTo.path())
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? SignInError.failed)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SignInError.failed)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}

// MARK: Keychain

/// The session in the Keychain, readable after the phone's first unlock so
/// syncing can carry on in the background.
private nonisolated enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mikecann.walkies.session",
        kSecAttrAccount as String: "convex-auth",
    ]

    static func load() -> Session? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
