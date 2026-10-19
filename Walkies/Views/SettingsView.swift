import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
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
