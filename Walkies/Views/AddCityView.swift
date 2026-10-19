import SwiftUI

struct AddCityView: View {
    @Environment(AppModel.self) private var model
    let onAdded: () -> Void

    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var hasSearched = false
    @State private var buildStatus: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            ForEach(results) { place in
                let tooBig = place.area > CityBuilder.maxArea
                Button {
                    add(place)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(place.name).font(.headline)
                        Text(place.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(tooBig
                             ? "\(place.kind.capitalized) · \(Format.area(place.area)) · too big, try a suburb"
                             : "\(place.kind.capitalized) · \(Format.area(place.area))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(tooBig || buildStatus != nil)
            }
        }
        .overlay {
            if searching {
                ProgressView()
            } else if !hasSearched {
                ContentUnavailableView(
                    "Find your patch",
                    systemImage: "magnifyingglass",
                    description: Text("Search for a suburb, town or city. Start small: a suburb is a few weeks of walks, a whole city is years.")
                )
            } else if results.isEmpty, errorMessage == nil {
                ContentUnavailableView(
                    "Nothing with a boundary",
                    systemImage: "map",
                    description: Text("OpenStreetMap doesn't have an outline for that. Try the suburb or town name on its own.")
                )
            }
        }
        .overlay {
            if let buildStatus {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(buildStatus).font(.headline)
                    Text("This can take up to a minute for a big place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .stickerCard(in: .rect(cornerRadius: 24))
            }
        }
        .navigationTitle("Add a city")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Suburb, town or city")
        .onSubmit(of: .search, search)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        errorMessage = nil
        Task {
            do {
                results = try await OSMClient.searchPlaces(text)
            } catch {
                results = []
                errorMessage = "Search didn't work. Check your connection and try again."
            }
            searching = false
            hasSearched = true
        }
    }

    private func add(_ place: PlaceResult) {
        errorMessage = nil
        buildStatus = "Getting \(place.name) ready…"
        Task {
            do {
                let city = try await CityBuilder.build(from: place, walks: model.walks) { buildStatus = $0 }
                model.add(city)
                buildStatus = nil
                onAdded()
            } catch {
                buildStatus = nil
                errorMessage = "Couldn't load the streets for \(place.name). OpenStreetMap might be busy, so try again in a minute."
            }
        }
    }
}
