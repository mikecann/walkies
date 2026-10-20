import AuthenticationServices
import Foundation
import Observation
import OSLog
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
    /// Their Google photo. Apple doesn't give one.
    var picture: String?
}

/// Signing in with Apple or Google through Convex Auth v2. Their sign-in pages run
/// in a secure sheet that ends on the deployment's own site, which bounces to
/// walkies://signed-in so the sheet hands the one-time code straight back. The
/// session lives in the Keychain.
@Observable
final class Account {
    enum Provider: String {
        case apple = "Apple"
        case google = "Google"
        #if DEBUG && targetEnvironment(simulator)
        case test = "Test"
        #endif
    }

    /// The tokens. Not observed: they change every few minutes as the access token is
    /// refreshed, and redrawing the whole app each time would reset open sheets.
    @ObservationIgnored private(set) var session: Session? {
        didSet {
            let next = Profile(session)
            if next != profile { profile = next }
        }
    }

    /// What the screens show about who's signed in. Only changes on sign-in, sign-out
    /// or a new name, email or photo, never on a token refresh.
    private var profile = Profile(nil)

    private struct Profile: Equatable {
        var signedIn = false
        var name: String?
        var email: String?
        var picture: String?

        init(_ session: Session?) {
            signedIn = session != nil
            name = session?.name
            email = session?.email
            picture = session?.picture
        }
    }

    var isSignedIn: Bool { profile.signedIn }
    /// Who's signed in, for tying this phone's data to them. Not observed.
    var userId: String? { session?.userId }
    /// The name to show for whoever's signed in.
    var displayName: String? { profile.name ?? profile.email }
    var email: String? { profile.email }
    /// Your photo for your head on the map picker, when you signed in with Google.
    var picture: URL? {
        #if DEBUG
        // `-testPictureURL <url>` stands in for a Google photo, since test accounts have none.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-testPictureURL"), flag + 1 < arguments.count {
            return URL(string: arguments[flag + 1])
        }
        #endif
        return profile.picture.flatMap(URL.init(string:))
    }

    @ObservationIgnored private let sheet = SignInSheet()
    @ObservationIgnored private var refreshing: Task<Session?, Never>?
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var automaticTestSignInRequested = false
    #endif

    /// - Parameter waitForUnlock: the Keychain can't be read before the phone's first
    ///   unlock, so leave the session for `loadSession()`.
    init(waitForUnlock: Bool = false) {
        session = waitForUnlock ? nil : Keychain.load()
        // didSet doesn't run in init.
        profile = Profile(session)
        #if DEBUG && targetEnvironment(simulator)
        automaticTestSignInRequested = session == nil && ProcessInfo.processInfo.arguments.contains("-testSignIn")
        #endif
    }

    func loadSession() {
        session = Keychain.load()
    }

    // MARK: Signing in

    func signIn(with provider: Provider) async throws {
        do {
            try await performSignIn(with: provider)
        } catch {
            log.error("\(provider.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func performSignIn(with provider: Provider) async throws {
        #if DEBUG && targetEnvironment(simulator)
        if provider == .test {
            let arguments = ProcessInfo.processInfo.arguments
            var args: [String: String] = [:]
            if let flag = arguments.firstIndex(of: "-testUserName"), flag + 1 < arguments.count,
               !arguments[flag + 1].hasPrefix("-") {
                args["name"] = arguments[flag + 1]
            }
            let result: CompleteResult = try await ConvexClient().mutation("auth:signInForTesting", args)
            try await finishSignIn(result)
            return
        }
        #endif
        let returnTo = Backend.site.appending(path: "app/signed-in")
        log.info("\(provider.rawValue, privacy: .public): starting on \(Backend.site.host() ?? "?", privacy: .public)")
        let start: StartResult = try await ConvexClient().mutation(
            "auth:startSignInWith\(provider.rawValue)", ["redirectTo": returnTo.absoluteString]
        )
        guard let page = URL(string: start.redirect) else { throw SignInError.failed }

        log.info("\(provider.rawValue, privacy: .public): opening \(page.host() ?? "?", privacy: .public)")
        let landed = try await sheet.open(page)
        log.info("\(provider.rawValue, privacy: .public): back on \(landed.scheme ?? "?", privacy: .public)://\(landed.host() ?? "", privacy: .public)")
        let query = URLComponents(url: landed, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "convexAuthError" })?.value {
            log.error("\(provider.rawValue, privacy: .public): provider said \(error, privacy: .public)")
            throw error == "access_denied" ? SignInError.cancelled : SignInError.failed
        }
        guard let code = query.first(where: { $0.name == "convexAuthCode" })?.value else { throw SignInError.failed }

        let result: CompleteResult = try await ConvexClient().mutation(
            "auth:completeSignInWith\(provider.rawValue)", ["code": code, "state": start.state]
        )
        log.info("\(provider.rawValue, privacy: .public): finished with \(result.status, privacy: .public)")
        try await finishSignIn(result)
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Consume once per launch, so signing out doesn't immediately sign back in.
    func takeAutomaticTestSignInRequest() -> Bool {
        let requested = automaticTestSignInRequested
        automaticTestSignInRequested = false
        return requested && !isSignedIn
    }
    #endif

    private func finishSignIn(_ result: CompleteResult) async throws {
        guard result.status == "complete", var tokens = result.tokens else { throw SignInError.failed }

        // Who this is, for Settings. Not essential, so a hiccup here doesn't stop sign-in.
        if let me: Me = try? await ConvexClient(token: tokens.accessToken).query("users:me") {
            me.apply(to: &tokens)
        }
        save(tokens)
    }

    /// Picks up a new name or photo for someone who's already signed in, such as a
    /// photo saved after they first signed in. Once a launch is plenty.
    func refreshProfile() async {
        guard let client = await client(),
              let me: Me = try? await client.query("users:me"),
              var tokens = session else { return }
        me.apply(to: &tokens)
        save(tokens)
    }

    // MARK: Using the session

    /// A client with a fresh access token, refreshing it first if it's about to run out.
    /// Nil when signed out or the session has ended.
    func client() async -> ConvexClient? {
        guard let session else { return nil }
        let now = Date.now.timeIntervalSince1970 * 1000
        // Access tokens can be short-lived (a minute on some deployments), so only
        // refresh in the last few seconds, not on every call.
        if session.accessTokenExpiresAt - now > 5_000 {
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
                tokens.picture = current.picture
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

    /// Signed out here straight away, so nothing can sync while the server's told.
    func signOut() async {
        let refreshToken = session?.refreshToken
        clear()
        if let refreshToken {
            let _: Nothing? = try? await ConvexClient().mutation("auth:signOut", ["refreshToken": refreshToken])
        }
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
    /// The sign-in sheet couldn't open, with iOS's error code.
    case sheet(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .failed: "Something went wrong signing in. Try again."
        case .sheet(let code): "Couldn't open the sign-in page (\(code)). Try again."
        }
    }
}

private nonisolated let log = Logger(subsystem: "com.mikecann.walkies", category: "signin")

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
    var picture: String?

    func apply(to session: inout Session) {
        session.name = name
        session.email = email
        session.picture = picture
    }
}

// MARK: The sign-in sheet

/// Runs Apple's or Google's sign-in page in a secure sheet that shares Safari's
/// sign-ins, and catches the moment it lands back on Walkies' own site.
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// The deployment's /app/signed-in page passes its query on to walkies://signed-in,
    /// which the sheet catches.
    func open(_ page: URL) async throws -> URL {
        let opened = Date.now
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: page,
                callback: .customScheme("walkies")
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                    return
                }
                let nsError = error.map { $0 as NSError }
                log.error("Sheet ended after \(Date.now.timeIntervalSince(opened), format: .fixed(precision: 1), privacy: .public)s: \(nsError?.domain ?? "no error", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                // A cancel that comes back before anyone could have seen the sheet is
                // iOS refusing to open it, not someone closing it.
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin,
                   Date.now.timeIntervalSince(opened) > 1.5 {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(throwing: SignInError.sheet(nsError?.code ?? 0))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                log.error("Sheet refused to start")
                continuation.resume(throwing: SignInError.sheet(-1))
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
