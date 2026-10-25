import ChefKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    @Environment(SyncEngine.self) private var sync
    @State private var confirmingSignOut = false
    @State private var cantSignOut: String?
    @State private var notUploaded: Int?
    @State private var confirmingDelete = false
    @State private var reallyDeleting = false
    @State private var deleting = false
    @State private var deleteFailed: String?
    /// Server secrets waiting for Mike's OK. Nil for everyone else, who never sees the list.
    @State private var waitingSecrets: [WaitingSecret]?
    @State private var reviewFailed: String?

    private var syncText: String {
        switch sync.status {
        case .syncing: return "Syncing…"
        case .failed(let reason): return sync.waiting > 0 ? "\(sync.waiting) waiting (\(reason))" : "Couldn't check (\(reason))"
        case .idle:
            if sync.waiting > 0 { return "\(sync.waiting) waiting to upload" }
            guard let last = sync.lastSynced else { return "Not synced yet" }
            return "Up to date, \(last.formatted(.relative(presentation: .named)))"
        }
    }

    private func signOut() {
        if model.activeWalk != nil {
            cantSignOut = "Finish your walk first."
        } else if sync.waiting > 0 {
            notUploaded = sync.waiting
        } else {
            confirmingSignOut = true
        }
    }

    /// Sync stops first, so nothing from this account comes back after the wipe.
    private func signOutNow() {
        Task {
            await sync.wipe()
            await account.signOut()
        }
    }

    /// Approves or hides a waiting secret, then looks again so it shows up on this phone
    /// too if it's in one of your places.
    private func review(_ secret: WaitingSecret, approve: Bool) {
        Task {
            guard let client = await account.client() else { reviewFailed = "Sign in again and try that once more."; return }
            do {
                if approve { try await SecretsReview.approve(secret, client) } else { try await SecretsReview.hide(secret, client) }
                withAnimation { waitingSecrets?.removeAll { $0.id == secret.id } }
                model.refreshLore(now: secret.osmId)
            } catch {
                reviewFailed = error.localizedDescription
            }
        }
    }

    private func deleteAccount() {
        if model.activeWalk != nil {
            cantSignOut = "Finish your walk first."
        } else {
            confirmingDelete = true
        }
    }

    /// The account goes first, so a phone that's offline keeps everything and can try
    /// again. Then this phone's copy, the same way signing out clears it.
    private func deleteAccountNow() {
        deleting = true
        Task {
            do {
                try await account.deleteAccount()
                await sync.wipe()
                await account.signOut()
            } catch {
                deleteFailed = error.localizedDescription
            }
            deleting = false
        }
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signed in as", value: account.displayName ?? "you")
                    if let email = account.email, email != account.displayName {
                        LabeledContent("Email", value: email)
                    }
                    LabeledContent("Sync", value: syncText)
                    Button("Sync now") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.status == .syncing)
                    Button("Sign out", role: .destructive, action: signOut)
                } header: {
                    Text("Account")
                }

                // Worded the same as "Deleting your account" on the website's privacy page.
                if account.isSignedIn {
                    Section {
                        Button(role: .destructive, action: deleteAccount) {
                            if deleting {
                                HStack { Text("Deleting…"); Spacer(); ProgressView() }
                            } else {
                                Text("Delete account")
                            }
                        }
                        .disabled(deleting)
                    } footer: {
                        Text("Deletes your account and everything in it from Walkies' server, then clears Walkies off this phone and signs you out. You can't undo it.")
                    }
                }

                if let waitingSecrets, !waitingSecrets.isEmpty {
                    Section {
                        ForEach(waitingSecrets) { secret in
                            WaitingSecretRow(secret: secret) {
                                review(secret, approve: true)
                            } onHide: {
                                review(secret, approve: false)
                            }
                        }
                    } header: {
                        Text("Secrets waiting for you")
                    } footer: {
                        Text("Written by the server for a new suburb. Only you can see these, and they stay hidden until you approve them.")
                    }
                }

                Section {
                    Toggle("Always on", isOn: $model.alwaysOn)
                } footer: {
                    Text("Records walks in the background. Walking and jogging count; bikes and cars don't.")
                }

                if model.alwaysOn && !model.tracker.hasAlwaysPermission {
                    Section {
                        Label("Set Location to Always so walks record when the app's closed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Count steps", isOn: $model.countSteps)
                    if model.countSteps && model.stepCounter.needsMotionAccess {
                        Text("Step counting needs Motion & Fitness access.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } footer: {
                    Text("Uses the phone's motion chip, no extra battery")
                }

                Section {
                    Button {
                        ChefKit.present()
                    } label: {
                        Label("Suggest a feature", systemImage: "lightbulb")
                    }
                    Link(destination: Backend.website.appending(path: "support")) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    Link(destination: Backend.website.appending(path: "privacy")) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                } footer: {
                    // OpenStreetMap's licence asks for credit wherever its data is shown.
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    Text("Walkies \(version). Suburb outlines and streets © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright).")
                }
            }
            .confirmationDialog("Sign out of Walkies?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive, action: signOutNow)
            } message: {
                Text("This clears Walkies off this phone. Everything's saved in your account and comes back when you sign in again.")
            }
            .confirmationDialog("Delete your Walkies account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { reallyDeleting = true }
            } message: {
                Text("Your walks, places, uncovered tiles, shells, secrets and feature requests are deleted from your account and this phone, and you leave any teams. This can't be undone.")
            }
            .alert("Are you sure?", isPresented: $reallyDeleting) {
                Button("Cancel", role: .cancel) {}
                Button("Delete everything", role: .destructive, action: deleteAccountNow)
            } message: {
                Text("Everything you've uncovered goes for good. You can sign in again later, but you'll start from scratch.")
            }
            .alert("Couldn't delete your account", isPresented: Binding(get: { deleteFailed != nil }, set: { if !$0 { deleteFailed = nil } })) {
                Button("OK") {}
            } message: {
                Text(deleteFailed ?? "")
            }
            .alert("Couldn't save that", isPresented: Binding(get: { reviewFailed != nil }, set: { if !$0 { reviewFailed = nil } })) {
                Button("OK") {}
            } message: {
                Text(reviewFailed ?? "")
            }
            .alert("Not yet", isPresented: Binding(get: { cantSignOut != nil }, set: { if !$0 { cantSignOut = nil } })) {
                Button("OK") {}
            } message: {
                Text(cantSignOut ?? "")
            }
            .alert("Not uploaded yet", isPresented: Binding(get: { notUploaded != nil }, set: { if !$0 { notUploaded = nil } })) {
                Button("Wait", role: .cancel) {}
                Button("Sign out anyway", role: .destructive, action: signOutNow)
            } message: {
                Text("\(notUploaded ?? 0) things haven't uploaded to your account yet. If you sign out now, they'll be lost.")
            }
            .scrollContentBackground(.hidden)
            .background(Color.cream)
            .task { await model.refreshStepsToday() }
            .task(id: account.isSignedIn) {
                guard account.isSignedIn, let client = await account.client() else { waitingSecrets = nil; return }
                waitingSecrets = await SecretsReview.waiting(client, userId: account.userId)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// One secret waiting for Mike: its sticker, title, story, kind and sources, with
/// Approve and Hide.
private struct WaitingSecretRow: View {
    let secret: WaitingSecret
    let onApprove: () -> Void
    let onHide: () -> Void

    var body: some View {
        let style = StickerStyle(category: secret.category)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: secret.stickerUrl) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    StickerArt(entry: secret.entry, size: 56)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(secret.title).font(.headline)
                    Label(style.label, systemImage: style.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(style.colour)
                    Text(secret.sensitive.isEmpty ? secret.suburb : "\(secret.suburb) · \(secret.sensitive.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(secret.body).font(.subheadline)
            ForEach(secret.sources, id: \.self) { source in
                if let url = URL(string: source), url.scheme != nil {
                    Link(url.host() ?? source, destination: url)
                        .font(.caption)
                        .buttonStyle(.borderless)
                } else {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                // Bordered, so each is its own button rather than the whole row.
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                Button("Hide", role: .destructive, action: onHide)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
