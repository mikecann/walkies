import SwiftUI

struct CitiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.cities.isEmpty {
                    ContentUnavailableView {
                        Label("No places yet", systemImage: "map")
                    } description: {
                        Text("Add your suburb or town, then go for a walk to start uncovering it.")
                    } actions: {
                        NavigationLink { AddCityView { dismiss() } } label: {
                            Label("Add a place", systemImage: "plus")
                        }
                        .buttonStyle(StickerButtonStyle())
                        .frame(width: 220)
                    }
                } else {
                    List {
                        ForEach(model.cities) { city in
                            Button {
                                model.select(city.id)
                                dismiss()
                            } label: {
                                CityRow(city: city, selected: city.id == model.selectedCityID)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { model.deleteCities(at: $0) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.cream)
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AddCityView { dismiss() } } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Add a place")
                }
            }
        }
    }
}

private struct CityRow: View {
    let city: City
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(city.name).font(.headline)
                    Text(city.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
                Text(city.progress.percentText)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }
            ProgressBar(value: city.progress)
            Text("\(city.visited.count) of \(city.tiles.count) tiles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
