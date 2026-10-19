import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(Account.self) private var account
    let onSignedIn: () -> Void

    @State private var username = ""
    @State private var working = false
    @State private var errorMessage: String?
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                stickers
                    .padding(.top, 48)

                VStack(spacing: 8) {
                    Text("Walkies")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("Walk the dog and clear the clouds off your suburb, one street at a time.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("Pick a username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($typing)
                        .onSubmit(continueWithUsername)
                        .padding(14)
                        .stickerCard(in: .rect(cornerRadius: 16))

                    Button(action: continueWithUsername) {
                        if working {
                            ProgressView().tint(.white)
                        } else {
                            Label("Continue", systemImage: "faceid")
                        }
                    }
                    .buttonStyle(StickerButtonStyle())
                    .disabled(working || username.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Use a passkey that's already on this phone") {
                        run { try await account.signInWithSavedPasskey() }
                    }
                    .font(.subheadline)
                    .disabled(working)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                }

                Text("A new username makes a new account. Walkies uses a passkey instead of a password: your phone keeps it, Face ID unlocks it, and your walks are kept safe in your account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.cream)
    }

    private var stickers: some View {
        ZStack {
            sticker("sticker-a-rest-stop-for-whales", size: 120, angle: -9, x: -78, y: 10)
            sticker("sticker-the-sundial-in-the-scrub", size: 110, angle: 8, x: 82, y: 18)
            sticker("sticker-baudins-crew-lives-here", size: 130, angle: -2, x: 0, y: -14)
        }
        .frame(height: 170)
    }

    private func sticker(_ name: String, size: CGFloat, angle: Double, x: CGFloat, y: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
    }

    private func continueWithUsername() {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        typing = false
        run { try await account.signIn(username: username) }
    }

    private func run(_ attempt: @escaping () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            do {
                try await attempt()
                onSignedIn()
            } catch let error as ASAuthorizationError where error.code == .canceled {
                // Closed the passkey sheet: nothing to say.
            } catch let error as ASAuthorizationError {
                errorMessage = "This phone couldn't use a passkey for Walkies (\(error.localizedDescription))."
            } catch let error as URLError {
                errorMessage = "Can't reach Walkies (\(error.code.rawValue)). Check your connection and try again."
            } catch is ConvexError {
                errorMessage = "Something went wrong on the Walkies server. Try again in a minute."
            } catch {
                errorMessage = error.localizedDescription
            }
            working = false
        }
    }
}
