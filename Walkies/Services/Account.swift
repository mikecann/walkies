import AuthenticationServices
import Foundation
import Observation
import OSLog
import Security
import SwiftUI
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

/// Signing in with Apple or Google through Convex Auth v2. Apple uses the iPhone's own
/// Sign in with Apple sheet (`AppleSignIn`). Google's sign-in page (and Apple's, if the
/// native sheet fails) runs in a secure sheet that ends on the deployment's own site,
/// which bounces to walkies://signed-in so the sheet hands the one-time code straight
/// back. The session lives in the Keychain.
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
    @ObservationIgnored private let apple = AppleSignIn()
    @ObservationIgnored private var refreshing: Task<Session?, Never>?
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var automaticTestSignInRequested = false
    #endif

    /// - Parameter waitForUnlock: the Keychain can't be read before the phone's first
    ///   unlock, so leave the session for `loadSession()`.
    init(waitForUnlock: Bool = false) {
        session = waitForUnlock ? nil : Keychain.load()
        #if DEBUG
        // Screenshots never show, or sync with, whoever's signed in.
        if ScreenshotMode.isOn { session = nil }
        #endif
        // didSet doesn't run in init.
        profile = Profile(session)
        #if DEBUG
        // The made-up explorer gets a name, so their head on the map isn't a "?".
        if ScreenshotMode.isOn { profile.name = ScreenshotMode.explorerName }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        automaticTestSignInRequested = session == nil && ProcessInfo.processInfo.arguments.contains("-testSignIn")
        #endif
    }

    func loadSession() {
        #if DEBUG
        if ScreenshotMode.isOn { return }
        #endif
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
        if provider == .apple {
            try await signInWithNativeApple()
            return
        }
        try await signInOnTheWeb(with: provider)
    }

    /// The iPhone's own Sign in with Apple sheet, then its identity token to the server. Only
    /// if that sheet itself fails (not a cancel, and not the server saying no) does it fall
    /// back to Apple's web page.
    private func signInWithNativeApple() async throws {
        let nonce = AppleSignInNonce.make()
        let credential: AppleSignIn.Credential
        do {
            credential = try await apple.authorize(nonce: nonce)
        } catch SignInError.cancelled {
            throw SignInError.cancelled
        } catch {
            log.error("Apple: native sheet failed (\(String(describing: error), privacy: .public)), trying the web page")
            try await signInOnTheWeb(with: .apple)
            return
        }
        // Apple only passes the name on the first time someone signs in to Walkies.
        var args = ["identityToken": credential.identityToken, "nonce": nonce.raw]
        if let first = credential.firstName, !first.isEmpty { args["firstName"] = first }
        if let last = credential.lastName, !last.isEmpty { args["lastName"] = last }
        let result: CompleteResult = try await ConvexClient().action("auth:signInWithAppleNative", args)
        log.info("Apple (native): finished with \(result.status, privacy: .public)")
        try await finishSignIn(result)
    }

    /// Apple's or Google's web page: in the secure sheet, or in Safari when iOS won't open
    /// the sheet (Apple's review devices refuse it), then the code back to Convex Auth.
    private func signInOnTheWeb(with provider: Provider) async throws {
        let returnTo = Backend.site.appending(path: "app/signed-in")
        log.info("\(provider.rawValue, privacy: .public): starting on \(Backend.site.host() ?? "?", privacy: .public)")
        let start: StartResult = try await ConvexClient().mutation(
            "auth:startSignInWith\(provider.rawValue)", ["redirectTo": returnTo.absoluteString]
        )
        guard let page = URL(string: start.redirect) else { throw SignInError.failed }

        log.info("\(provider.rawValue, privacy: .public): opening \(page.host() ?? "?", privacy: .public)")
        let landed: URL
        do {
            landed = try await sheet.open(page)
        } catch SignInError.sheet(let code) {
            log.error("\(provider.rawValue, privacy: .public): sheet refused (\(code, privacy: .public)), opening Safari")
            landed = try await sheet.openInBrowser(page)
        }
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

    /// Deletes the account and everything in it on the server (users:deleteAccount). The
    /// server signs every session out at once; wiping this phone and `signOut()` are up
    /// to the caller, once this has worked.
    func deleteAccount() async throws {
        guard let client = await client() else { throw AccountError.offline }
        do {
            let _: Nothing = try await client.mutation("users:deleteAccount")
        } catch is URLError {
            throw AccountError.offline
        }
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

nonisolated enum AccountError: LocalizedError {
    case offline

    var errorDescription: String? {
        "Couldn't reach Walkies. Check you're online and try again."
    }
}

nonisolated enum SignInError: LocalizedError {
    case cancelled
    case failed
    /// The sign-in sheet couldn't open, with iOS's error code.
    case sheet(Int)
    /// The iPhone's own Sign in with Apple sheet failed, with its error code.
    case nativeApple(Int)
    /// Safari wouldn't open the sign-in page either.
    case browser

    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .failed: "Something went wrong signing in. Try again."
        case .sheet(let code): "Couldn't open the sign-in page (\(code)). Try again."
        case .nativeApple(let code): "Couldn't sign in with Apple (\(code)). Try again."
        case .browser: "Couldn't open Safari to sign in. Try again."
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
        let result: Result<URL, SignInError> = await withCheckedContinuation { continuation in
            // start() can say no and the completion handler still fire with an error, and
            // resuming twice crashes the app (Poddle's PODDLE-8), so the first ending wins.
            let finish = FirstAnswer<Result<URL, SignInError>> { continuation.resume(returning: $0) }
            let session = ASWebAuthenticationSession(
                url: page,
                callback: .customScheme("walkies")
            ) { url, error in
                if let url {
                    finish(.success(url))
                    return
                }
                let nsError = error.map { $0 as NSError }
                log.error("Sheet ended after \(Date.now.timeIntervalSince(opened), format: .fixed(precision: 1), privacy: .public)s: \(nsError?.domain ?? "no error", privacy: .public) \(nsError?.code ?? 0, privacy: .public)")
                // A cancel that comes back before anyone could have seen the sheet is
                // iOS refusing to open it, not someone closing it.
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin,
                   Date.now.timeIntervalSince(opened) > 1.5 {
                    finish(.failure(.cancelled))
                } else {
                    finish(.failure(.sheet(nsError?.code ?? 0)))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                log.error("Sheet refused to start")
                finish(.failure(.sheet(-1)))
            }
        }
        session = nil
        return try result.get()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { Self.appWindow() }
    }

    /// The app's window to show a sign-in sheet over.
    static func appWindow() -> UIWindow {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }

    // MARK: Safari, when iOS won't open the sheet

    /// Waiting for Safari to come back on walkies://signed-in, and whether Walkies has gone
    /// to the background since (so coming back to the foreground means they've returned).
    private static var browserWait: FirstAnswer<Result<URL, SignInError>>?
    private static var leftForBrowser = false

    /// The same sign-in page in Safari. Its last stop (/app/signed-in) sends Safari on to
    /// walkies://signed-in, which reopens Walkies and comes in through `browserReturned`.
    func openInBrowser(_ page: URL) async throws -> URL {
        let result: Result<URL, SignInError> = await withCheckedContinuation { continuation in
            let finish = FirstAnswer<Result<URL, SignInError>> { continuation.resume(returning: $0) }
            Self.browserWait = finish
            Self.leftForBrowser = false
            UIApplication.shared.open(page) { opened in
                if !opened { finish(.failure(.browser)) }
            }
        }
        Self.browserWait = nil
        return try result.get()
    }

    /// walkies://signed-in, from Safari. True when it was ours to handle.
    static func browserReturned(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "walkies", url.host?.lowercased() == "signed-in" else { return false }
        browserWait?(.success(url))
        return true
    }

    /// Back in Walkies without Safari sending them back on the link: they gave up, so the
    /// buttons come back. A short wait first, since the link and the app becoming active can
    /// arrive in either order.
    static func scenePhaseChanged(to phase: ScenePhase) {
        guard let waiting = browserWait else { return }
        if phase == .background { leftForBrowser = true }
        guard phase == .active, leftForBrowser else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            waiting(.failure(.cancelled))
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
