import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var cantSignOut: String?

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
            cantSignOut = "\(sync.waiting) things haven't uploaded to your account yet. Wait until there's signal and they've synced, or they'd be lost."
        } else {
            confirmingSignOut = true
        }
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signed in as", value: account.username ?? "you")
                    LabeledContent("Sync", value: syncText)
                    Button("Sync now") {
                        Task { await sync.sync() }
                    }
                    .disabled(sync.status == .syncing)
                    Button("Sign out", role: .destructive, action: signOut)
                } header: {
                    Text("Account")
                } footer: {
                    Text("Walks are kept on this phone and copied to your account whenever there's signal, so nothing's lost if you're out of range.")
                }

                Section {
                    Toggle("Always on", isOn: $model.alwaysOn)
                } footer: {
                    Text("Walkies records in the background, so there's no Start walk to remember. Just head out. GPS pauses while you're sitting still, but it will still use more battery than starting walks yourself.")
                }

                if model.alwaysOn && !model.tracker.hasAlwaysPermission {
                    Section {
                        Label("Location is set to While Using the App, so tracking stops once the app's been closed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text("In Settings, tap Location and choose Always.")
                    }
                }

                Section {
                    Toggle("3D view", isOn: $model.tilted3D)
                } footer: {
                    Text("Tilts the map and shows Apple's 3D buildings and trees, where it has them. The whole-suburb view stays flat.")
                }

                Section {
                    LabeledContent("Counts", value: "Walking and jogging")
                    LabeledContent("Doesn't count", value: "Bikes and cars")
                } footer: {
                    Text("Anything faster than about 12 km/h, or that your phone thinks is cycling or driving, doesn't uncover tiles.")
                }
            }
            .confirmationDialog("Sign out of Walkies?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await account.signOut()
                        model.wipeLocalData()
                        sync.reset()
                    }
                }
            } message: {
                Text("This clears Walkies off this phone. Everything's saved in your account and comes back when you sign in again.")
            }
            .alert("Not yet", isPresented: Binding(get: { cantSignOut != nil }, set: { if !$0 { cantSignOut = nil } })) {
                Button("OK") {}
            } message: {
                Text(cantSignOut ?? "")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
