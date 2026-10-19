import SwiftUI

struct SignInView: View {
    @Environment(Account.self) private var account
    let onSignedIn: () -> Void

    @State private var working: Account.Provider?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                stickers
                    .padding(.top, 48)

                VStack(spacing: 8) {
                    Text("Walkies")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("Clear the clouds off your suburb one street at a time, and find the secrets hiding underneath.")
                        .font(.body)
                        .foregroundStyle(Color.ink.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button { signIn(with: .apple) } label: {
                        label("Sign in with Apple", provider: .apple) {
                            Image(systemName: "apple.logo").font(.title3)
                        }
                    }
                    .buttonStyle(StickerButtonStyle(fill: .black))

                    Button { signIn(with: .google) } label: {
                        label("Continue with Google", provider: .google) {
                            GoogleG()
                        }
                        .foregroundStyle(Color.ink)
                    }
                    .buttonStyle(StickerButtonStyle(fill: .white, foreground: .ink))

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                }
                .disabled(working != nil)

                Text("Your walks are kept on your phone and backed up to your account. Walkies uses your email to let you know about things like new secrets.")
                    .font(.footnote)
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color.cream)
    }

    private func label(_ title: String, provider: Account.Provider, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 10) {
            if working == provider {
                ProgressView()
            } else {
                icon()
            }
            Text(title)
        }
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

    private func signIn(with provider: Account.Provider) {
        working = provider
        errorMessage = nil
        Task {
            do {
                try await account.signIn(with: provider)
                onSignedIn()
            } catch SignInError.cancelled {
                // Closed the sheet: nothing to say.
            } catch let error as URLError {
                errorMessage = "Can't reach Walkies (\(error.code.rawValue)). Check your connection and try again."
            } catch is ConvexError {
                errorMessage = "Something went wrong on the Walkies server. Try again in a minute."
            } catch {
                errorMessage = error.localizedDescription
            }
            working = nil
        }
    }
}

/// Google's "G", drawn in its four colours.
private struct GoogleG: View {
    var body: some View {
        Text("G")
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundStyle(
                AngularGradient(
                    colors: [.red, .yellow, .green, .blue, .blue, .red],
                    center: .center
                )
            )
    }
}
