import ChefKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var cantSignOut: String?
    @State private var notUploaded: Int?

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

                Section("History") {
                    NavigationLink {
                        WalkHistoryView()
                    } label: {
                        LabeledContent("Past walks", value: "\(model.walks.count)")
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
                    Button {
                        ChefKit.present()
                    } label: {
                        Label("Suggest a feature", systemImage: "lightbulb")
                    }
                }
            }
            .confirmationDialog("Sign out of Walkies?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive, action: signOutNow)
            } message: {
                Text("This clears Walkies off this phone. Everything's saved in your account and comes back when you sign in again.")
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
