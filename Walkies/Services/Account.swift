import AuthenticationServices
import Foundation
import Observation
import Security
import UIKit

/// Session tokens from Convex Auth.
nonisolated struct Session: Codable, Sendable {
    var accessToken: String
    /// Milliseconds since 1970, as Convex Auth sends them.
    var accessTokenExpiresAt: Double
    var refreshToken: String
    var refreshTokenExpiresAt: Double
    var userId: String
    var username: String?
}

/// Signing in with a passkey through Convex Auth v2. The username picks the
/// account: a new one makes an account and a passkey, an existing one asks for its
/// passkey. Face ID does the rest. The session lives in the Keychain.
@Observable
final class Account {
    private(set) var session: Session?

    var isSignedIn: Bool { session != nil }
    var username: String? { session?.username }

    @ObservationIgnored private let ceremony = PasskeyCeremony()
    @ObservationIgnored private var refreshing: Task<Session?, Never>?

    init() {
        session = Keychain.load()
    }

    // MARK: Signing in

    /// Signs in to the account with this username, or creates it if it's free.
    func signIn(username: String) async throws {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let start: StartResult = try await ConvexClient().mutation(
            "auth:startSignInWithUsernamePasskey", ["username": name]
        )
        if let error = start.userError { throw SignInError(code: error.error) }
        guard let options = start.options else { throw SignInError(code: "PROTOCOL_ERROR") }

        if start.step == "register" {
            let response = try await ceremony.register(options: options)
            let result: FinishResult = try await ConvexClient().mutation(
                "auth:finishSignUpWithUsernamePasskey", SignUpArgs(username: name, response: response)
            )
            try complete(result, username: name)
        } else {
            let response = try await ceremony.assert(options: options)
            let result: FinishResult = try await ConvexClient().mutation(
                "auth:finishSignInWithUsernamePasskey", ["response": response]
            )
            try complete(result, username: name)
        }
    }

    /// Lets iOS offer whichever Walkies passkey is saved on the phone, no username needed.
    func signInWithSavedPasskey() async throws {
        let start: AutofillStart = try await ConvexClient().mutation("auth:startAutofillSignInWithUsernamePasskey")
        let response = try await ceremony.assert(options: start.options)
        let result: FinishResult = try await ConvexClient().mutation(
            "auth:finishSignInWithUsernamePasskey", ["response": response]
        )
        try complete(result, username: nil)
    }

    private func complete(_ result: FinishResult, username: String?) throws {
        if let error = result.userError { throw SignInError(code: error.error) }
        guard var tokens = result.tokens else { throw SignInError(code: "PROTOCOL_ERROR") }
        tokens.username = result.username ?? username
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
                tokens.username = current.username
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

nonisolated struct SignInError: LocalizedError {
    var code: String

    var errorDescription: String? {
        switch code {
        case "USERNAME_TOO_SHORT": "Pick a username first."
        case "USERNAME_HAS_INVALID_CHARACTERS": "Usernames can't have those characters in them."
        case "USERNAME_HAS_SURROUNDING_WHITESPACE": "Usernames can't start or end with a space."
        case "USERNAME_TAKEN": "That username's already taken."
        case "UNKNOWN_CREDENTIAL", "PASSKEY_NOT_FOUND": "That passkey isn't for a Walkies account."
        case "CHALLENGE_EXPIRED": "That took a bit too long. Try again."
        default: "Something went wrong signing in. Try again."
        }
    }
}

// MARK: Wire formats

private nonisolated struct StartResult: Decodable {
    var success: Bool
    var step: String?
    var options: PasskeyOptions?
    var userError: UserError?
}

private nonisolated struct AutofillStart: Decodable {
    var options: PasskeyOptions
}

private nonisolated struct FinishResult: Decodable {
    var status: String
    var tokens: Session?
    var username: String?
    var userError: UserError?
}

private nonisolated struct RefreshResult: Decodable {
    var kind: String
    var tokens: Session?
}

private nonisolated struct UserError: Decodable {
    var error: String
}

private nonisolated struct SignUpArgs: Encodable {
    var username: String
    var response: PasskeyResponse
}

/// The WebAuthn options Convex Auth sends, covering both registration and sign-in.
nonisolated struct PasskeyOptions: Decodable, Sendable {
    struct Party: Decodable, Sendable { var id: String }
    struct User: Decodable, Sendable { var id: String; var name: String }
    struct Descriptor: Decodable, Sendable { var id: String }

    var challenge: String
    var rp: Party?
    var user: User?
    var rpId: String?
    var allowCredentials: [Descriptor]?
}

/// A passkey's answer, in the JSON shape the server checks (SimpleWebAuthn's).
nonisolated struct PasskeyResponse: Encodable, Sendable {
    struct Body: Encodable, Sendable {
        var clientDataJSON: String
        var attestationObject: String?
        var transports: [String]?
        var authenticatorData: String?
        var signature: String?
        var userHandle: String?
    }
    struct NoExtensions: Encodable, Sendable {}

    var id: String
    var rawId: String
    var response: Body
    var clientExtensionResults = NoExtensions()
    var type = "public-key"
}

// MARK: Passkeys

/// Runs one passkey request through iOS (Face ID and the passkey sheet).
final class PasskeyCeremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func register(options: PasskeyOptions) async throws -> PasskeyResponse {
        guard let party = options.rp, let user = options.user,
              let challenge = Data(base64URL: options.challenge), let userID = Data(base64URL: user.id)
        else { throw SignInError(code: "PROTOCOL_ERROR") }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: party.id)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: user.name, userID: userID)
        request.userVerificationPreference = .required
        guard let credential = try await perform(request).credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject
        else { throw SignInError(code: "PROTOCOL_ERROR") }
        let id = credential.credentialID.base64URL
        return PasskeyResponse(id: id, rawId: id, response: .init(
            clientDataJSON: credential.rawClientDataJSON.base64URL,
            attestationObject: attestation.base64URL,
            transports: ["internal", "hybrid"]
        ))
    }

    func assert(options: PasskeyOptions) async throws -> PasskeyResponse {
        guard let challenge = Data(base64URL: options.challenge) else { throw SignInError(code: "PROTOCOL_ERROR") }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.rpId ?? Backend.site.host()!)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = (options.allowCredentials ?? []).compactMap { descriptor in
            Data(base64URL: descriptor.id).map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init)
        }
        guard let credential = try await perform(request).credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        else { throw SignInError(code: "PROTOCOL_ERROR") }
        let id = credential.credentialID.base64URL
        return PasskeyResponse(id: id, rawId: id, response: .init(
            clientDataJSON: credential.rawClientDataJSON.base64URL,
            authenticatorData: credential.rawAuthenticatorData.base64URL,
            signature: credential.signature.base64URL,
            userHandle: credential.userID.base64URL
        ))
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: authorization)
            continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
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

// MARK: Base64URL

nonisolated extension Data {
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
