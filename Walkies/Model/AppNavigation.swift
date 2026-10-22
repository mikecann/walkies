import Observation

/// Where you are in the app: which tab's showing, which part of the progress page,
/// and what's open over the top. The map's the first tab and where the app opens.
@Observable
final class AppNavigation {
    enum Tab: Hashable, CaseIterable {
        case map, secrets, progress, walks, settings
    }

    /// The progress page's parts, picked from the row along its top.
    enum ProgressSection: String, CaseIterable, Identifiable {
        case level = "Level", quests = "Quests", shop = "Shop", wardrobe = "Wardrobe", spyglass = "Spyglass"
        var id: Self { self }
    }

    var tab: Tab = .map
    var progressSection: ProgressSection = .level
    /// A secret's card, over whichever tab is showing: from a pin, the book or a past walk.
    var openSecret: LoreEntry?
    /// Your places, from the place chip on the map.
    var showingPlaces = false

    /// The shells chip, or the celebration's "Level up": the progress tab, at that part.
    func showProgress(_ section: ProgressSection = .level) {
        progressSection = section
        tab = .progress
    }

    /// Back to the map, for a walk replay to play over it.
    func showMap() {
        tab = .map
    }
}
