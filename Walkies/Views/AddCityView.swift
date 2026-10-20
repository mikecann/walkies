import MapKit
import SwiftUI

/// Finding a place to add. Suggestions come up as you type, from Apple's search
/// (OpenStreetMap's Nominatim asks apps not to search as you type). Picking one
/// looks up its boundary on OpenStreetMap, and if there's one clear match it's
/// added straight away; otherwise you choose. Pressing Search asks OpenStreetMap
/// directly.
struct AddCityView: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    let onAdded: () -> Void

    @State private var query = ""
    @State private var completer = PlaceCompleter()
    /// Boundaries from OpenStreetMap, once you've picked a suggestion or pressed Search.
    @State private var results: [PlaceResult]?
    @State private var searching = false
    @State private var buildStatus: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                if let results {
                    ForEach(results) { place in
                        let tooBig = place.area > CityBuilder.maxArea
                        ResultRow(
                            title: place.name,
                            detail: place.detail,
                            note: tooBig
                                ? "\(place.kind.capitalized) · \(Format.area(place.area)) · too big, try a suburb"
                                : "\(place.kind.capitalized) · \(Format.area(place.area))",
                            icon: "plus"
                        ) { add(place) }
                        .disabled(tooBig || buildStatus != nil)
                        .opacity(tooBig ? 0.5 : 1)
                    }
                } else {
                    ForEach(completer.suggestions, id: \.self) { suggestion in
                        ResultRow(title: suggestion.title, detail: suggestion.subtitle, note: nil, icon: "chevron.right") {
                            pick(suggestion)
                        }
                        .disabled(searching || buildStatus != nil)
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.cream)
        .overlay { emptyState }
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
        .navigationTitle("Add a place")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Suburb, town or city")
        .onChange(of: query) {
            results = nil
            errorMessage = nil
            completer.search(query)
        }
        .onSubmit(of: .search) { search(query) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searching {
            ProgressView().controlSize(.large)
        } else if let results, results.isEmpty, errorMessage == nil {
            ContentUnavailableView(
                "Nothing with a boundary",
                systemImage: "map",
                description: Text("OpenStreetMap doesn't have an outline for that. Try the suburb or town name on its own.")
            )
        } else if results == nil, completer.suggestions.isEmpty, buildStatus == nil {
            ContentUnavailableView(
                "Find your patch",
                systemImage: "magnifyingglass",
                description: Text("Search for a suburb, town or city. Start small: a suburb is a few weeks of walks, a whole city is years.")
            )
        }
    }

    /// A suggestion from Apple: find its boundary, and add it if it's clearly the one.
    private func pick(_ suggestion: MKLocalSearchCompletion) {
        let text = [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        search(text) { found in
            // Apple's titles can carry the state too ("Geographe, WA").
            let name = (suggestion.title.split(separator: ",").first.map(String.init) ?? suggestion.title)
                .trimmingCharacters(in: .whitespaces).lowercased()
            let usable = found.filter { $0.area <= CityBuilder.maxArea }
            if let first = usable.first, first.name.lowercased() == name,
               usable.dropFirst().allSatisfy({ $0.name.lowercased() != name }) {
                add(first)
            }
        }
    }

    private func search(_ text: String, then: @escaping ([PlaceResult]) -> Void = { _ in }) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        errorMessage = nil
        Task {
            do {
                let found = try await OSMClient.searchPlaces(text)
                results = found
                then(found)
            } catch {
                results = []
                errorMessage = "Search didn't work. Check your connection and try again."
            }
            searching = false
        }
    }

    private func add(_ place: PlaceResult) {
        errorMessage = nil
        buildStatus = "Getting \(place.name) ready…"
        Task {
            do {
                try await model.addPlace(place) { buildStatus = $0 }
                buildStatus = nil
                onAdded()
            } catch {
                buildStatus = nil
                errorMessage = model.currentCrewID == nil
                    ? "Couldn't load the streets for \(place.name). OpenStreetMap might be busy, so try again in a minute."
                    : "\(error.localizedDescription) Any prepared crew place is saved and will retry when there's signal."
            }
        }
    }
}

/// One place to pick, as a full-width card that's easy to hit.
private struct ResultRow: View {
    let title: String
    let detail: String
    let note: String?
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 48)
                    .background(Color.badgeTeal, in: Hexagon())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink.opacity(0.65))
                            .lineLimit(2)
                    }
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Color.ink.opacity(0.5))
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.burnt)
            }
            .foregroundStyle(Color.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .stickerCard(in: .rect(cornerRadius: 20))
        }
        .buttonStyle(PressScale())
    }
}

/// Apple's place suggestions as you type, just suburbs, towns and cities.
@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.addressFilter = MKAddressFilter(including: [.locality, .subLocality, .administrativeArea, .subAdministrativeArea])
    }

    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            completer.cancel()
            suggestions = []
        } else {
            completer.queryFragment = text
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = Array(completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            suggestions = []
        }
    }
}
