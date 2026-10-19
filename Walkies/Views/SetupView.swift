import CoreMotion
import SwiftUI

/// First run, straight after signing in. Walkies only really works always on, so this
/// switches it on and asks for what it needs one prompt at a time, with a line on
/// what each is for: location, then motion, then notifications for secrets.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var step = Step.location
    @State private var asking = false

    private enum Step { case location, secrets }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            art
                .frame(height: 190)

            VStack(spacing: 12) {
                Text(step == .location ? "Just head out" : "Secrets hide under the clouds")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(step == .location
                     ? "Walkies runs quietly in the background. Whenever you're out on foot, it clears the clouds as you go, so there's nothing to start or stop."
                     : "Local history and odd little stories are tucked under some of the tiles. Walkies can give you a ping when you walk over one.")
                    .font(.body)
                    .foregroundStyle(Color.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            VStack(spacing: 14) {
                if step == .location {
                    Text("iOS asks a couple of things. Tap Allow While Using App, then Change to Always Allow when it checks back later. Motion & Fitness lets Walkies tell walking from cycling or driving.")
                        .font(.footnote)
                        .foregroundStyle(Color.ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button(action: allowLocation) {
                        label("Allow location", working: asking)
                    }
                    .buttonStyle(StickerButtonStyle())
                } else {
                    Button(action: allowNotifications) {
                        label("Allow notifications", working: asking)
                    }
                    .buttonStyle(StickerButtonStyle())
                    Button("Not now", action: finish)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink.opacity(0.6))
                }

                HStack(spacing: 8) {
                    dot(on: step == .location)
                    dot(on: step == .secrets)
                }
                .padding(.top, 4)
            }
            .disabled(asking)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background(Color.cream)
        .animation(.snappy, value: step)
    }

    @ViewBuilder
    private var art: some View {
        if step == .location {
            Image("icon-walk")
                .resizable()
                .scaledToFit()
                .frame(width: 190)
                .rotationEffect(.degrees(-8))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 5)
                .transition(.scale.combined(with: .opacity))
        } else {
            ZStack {
                sticker("sticker-the-sundial-in-the-scrub", size: 120, angle: 9, x: 70, y: 16)
                sticker("sticker-a-rest-stop-for-whales", size: 120, angle: -10, x: -72, y: 22)
                Image("icon-book")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 130)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 5)
                    .offset(y: -12)
            }
            .transition(.scale.combined(with: .opacity))
        }
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

    private func label(_ title: String, working: Bool) -> some View {
        HStack(spacing: 10) {
            if working { ProgressView().tint(.white) }
            Text(title).font(.title3.weight(.semibold))
        }
    }

    private func dot(on: Bool) -> some View {
        Hexagon()
            .fill(on ? Color.burnt : Color.ink.opacity(0.2))
            .frame(width: 10, height: 11)
    }

    /// Location first, then motion straight after, each waiting for its answer.
    private func allowLocation() {
        asking = true
        Task {
            if model.tracker.authorization == .notDetermined {
                model.tracker.requestAlwaysPermission()
                while model.tracker.authorization == .notDetermined {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            model.motion.start()
            if CMMotionActivityManager.isActivityAvailable() {
                for _ in 0..<200 where CMMotionActivityManager.authorizationStatus() == .notDetermined {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            asking = false
            step = .secrets
        }
    }

    private func allowNotifications() {
        asking = true
        Task {
            await Notifier.requestPermission()
            asking = false
            finish()
        }
    }

    private func finish() {
        model.alwaysOn = true
        model.setupDone = true
    }
}
