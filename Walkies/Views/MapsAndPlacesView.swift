import SwiftUI

struct MapsAndPlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingPlace = false

    var body: some View {
        NavigationStack {
            // Keep these independent controls out of List's row tap handling.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Places").font(.headline)
                        ForEach(model.cities) { city in
                            Button {
                                model.select(city.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(city.name)
                                    Spacer()
                                    Text(city.progress.percentText).monospacedDigit()
                                    if model.selectedCityID == city.id { Image(systemName: "checkmark") }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.selectedCityID == city.id ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .stickerCard(in: .rect(cornerRadius: 24))

                    Button { addingPlace = true } label: {
                        Label("Add a place", systemImage: "plus")
                    }
                    .buttonStyle(StickerButtonStyle())
                }
                .padding()
            }
            .background(Color.sand.opacity(0.45))
            .foregroundStyle(Color.ink)
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $addingPlace) {
                AddCityView { dismiss() }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.burnt)
        .environment(\.colorScheme, .light)
    }
}

