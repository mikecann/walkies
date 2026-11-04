import AuthenticationServices
import CryptoKit
import Foundation
import Synchronization
import UIKit

/// Sign in with Apple through the iPhone's own sheet (Face ID, no web page), which hands back
/// an identity token for `auth:signInWithAppleNative` to check. In Poddle, Apple's App Review
/// devices refused the web sign-in sheet outright, every time, and this doesn't need a browser.
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential: Sendable {
        var identityToken: String
        var firstName: String?
        var lastName: String?
    }

    private var finish: FirstAnswer<Result<Credential, SignInError>>?
    private var controller: ASAuthorizationController?

    func authorize(nonce: AppleSignInNonce) async throws -> Credential {
        let result: Result<Credential, SignInError> = await withCheckedContinuation { continuation in
            // The delegate could in principle hear twice (an error after a cancel); resuming
            // twice would crash, so the first answer wins.
            finish = FirstAnswer { continuation.resume(returning: $0) }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashed
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
        finish = nil
        controller = nil
        return try result.get()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                finish?(.failure(.nativeApple(-1)))
                return
            }
            finish?(.success(Credential(identityToken: token, firstName: credential.fullName?.givenName,
                                        lastName: credential.fullName?.familyName)))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let code = (error as NSError).code
        MainActor.assumeIsolated {
            finish?(.failure(code == ASAuthorizationError.canceled.rawValue ? .cancelled : .nativeApple(code)))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { SignInSheet.appWindow() }
    }
}

/// The nonce for one native Sign in with Apple: the request carries `hashed`, Apple signs it
/// into the identity token, and the backend checks `raw` against it, so a token only works
/// for the sign-in it was made for.
nonisolated struct AppleSignInNonce: Sendable, Hashable {
    let raw: String

    static func make() -> AppleSignInNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return AppleSignInNonce(raw: bytes.map { String(format: "%02x", $0) }.joined())
    }

    var hashed: String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Passes on only the first value it's given. For handing a callback API's ending to a
/// continuation, which crashes the app if it's resumed twice: ASWebAuthenticationSession can
/// call its completion handler with an error and also return false from start() (Poddle's
/// PODDLE-8 crash), so both paths go through one of these.
nonisolated final class FirstAnswer<Value: Sendable>: Sendable {
    private let deliver: @Sendable (Value) -> Void
    private let done = Mutex(false)

    init(_ deliver: @escaping @Sendable (Value) -> Void) {
        self.deliver = deliver
    }

    func callAsFunction(_ value: Value) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { deliver(value) }
    }
}
