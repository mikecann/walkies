import Foundation
import Testing
@testable import Walkies

/// Native Sign in with Apple's nonce and the guard that keeps sign-in sheets from resuming
/// their continuation twice (AppleSignIn.swift).
struct AppleSignInTests {
    @Test func theNonceTheRequestCarriesIsTheSHA256OfTheRawOne() {
        // The backend checks sha256(raw) as lowercase hex against the token's nonce claim.
        let nonce = AppleSignInNonce(raw: "abc")
        #expect(nonce.hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func everySignInGetsItsOwnNonce() {
        let a = AppleSignInNonce.make(), b = AppleSignInNonce.make()
        #expect(a != b)
        #expect(a.raw.count == 64)
    }

    @Test func onlyTheFirstAnswerIsPassedOn() async {
        let result: Int = await withCheckedContinuation { continuation in
            let finish = FirstAnswer<Int> { continuation.resume(returning: $0) }
            finish(1)
            finish(2) // would crash the app if it reached the continuation
        }
        #expect(result == 1)
    }

    @Test func safarisSignInReturnIsOursAndATeamLinkIsNot() {
        #expect(SignInSheet.browserReturned(URL(string: "walkies://signed-in?convexAuthCode=x")!))
        #expect(!SignInSheet.browserReturned(URL(string: "walkies://join/ABCDEFGH")!))
    }
}
