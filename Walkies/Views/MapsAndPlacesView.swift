import SwiftUI

struct MapsAndPlacesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingPlace = false
    @State private var editing = false
    @State private var deleting: City?

    var body: some View {
        NavigationStack {
            // Keep these independent controls out of List's row tap handling.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Places").font(.headline)
                        ForEach(model.cities) { city in
                            HStack(spacing: 12) {
                                Button {
                                    model.select(city.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(city.name)
                                        Spacer()
                                        Text(city.progress.percentText).monospacedDigit()
                                        if model.selectedCityID == city.id && !editing { Image(systemName: "checkmark") }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .disabled(editing)
                                .accessibilityAddTraits(model.selectedCityID == city.id ? .isSelected : [])
                                if editing {
                                    Button { deleting = city } label: {
                                        Image(systemName: "trash.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 34, height: 34)
                                            .background(Color.red, in: Circle())
                                    }
                                    .buttonStyle(PressScale())
                                    .accessibilityLabel("Delete \(city.name)")
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
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
            .toolbar {
                if !editing && !model.cities.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Edit") { withAnimation(.snappy) { editing = true } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if editing { withAnimation(.snappy) { editing = false } } else { dismiss() }
                    }
                }
            }
            .confirmationDialog(
                deleting.map { "Delete \($0.name)?" } ?? "",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { city in
                Button("Delete \(city.name)", role: .destructive) {
                    model.deleteCity(city.id)
                    if model.cities.isEmpty { editing = false }
                }
                Button("Keep it", role: .cancel) {}
            } message: { _ in
                Text("Its tiles and secrets come off this map, here and on your other phones. Your walks are kept.")
            }
        }
        .tint(.burnt)
        .environment(\.colorScheme, .light)
    }
}

