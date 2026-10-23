#if DEBUG
import CoreLocation
import Foundation

/// App Store screenshots (scripts/screenshots.sh): `-WalkiesScreen <screen>` opens
/// Walkies straight on that screen as a made-up explorer a few weeks into Fremantle, WA,
/// built from `appstore/sample/fremantle.json` (the script copies it into the app's
/// Application Support as ScreenshotSample.json). Everything lives in a scratch folder
/// that's made again on every launch, the saved session isn't read, and nothing syncs,
/// so it never shows or touches anyone's real walks. Debug builds only.
enum ScreenshotMode {
    enum Screen: String, CaseIterable {
        case map, recap, secrets, progress, quests, walks, settings
    }

    static let screen: Screen? = LaunchArguments.value(after: "-WalkiesScreen").flatMap(Screen.init(rawValue:))
    static var isOn: Bool { screen != nil }

    static let sampleFile = URL.applicationSupportDirectory.appending(path: "ScreenshotSample.json")
    private static let root = URL.temporaryDirectory.appending(path: "WalkiesScreenshots", directoryHint: .isDirectory)

    /// Secrets the explorer has found: stories from the Busselton lore, which is all
    /// there is so far. Their area shows opened up in the book.
    static let secretsArea = "Busselton"
    private static let foundCount = 9

    /// A fresh store holding the sample, or an empty one if the sample file's missing.
    static func makeStore(now: Date = .now) -> Store {
        try? FileManager.default.removeItem(at: root)
        let store = Store(root: root)
        guard let data = try? Data(contentsOf: sampleFile),
              let place = try? JSONDecoder().decode(CachedPlaceData.self, from: data)
        else {
            print("ScreenshotMode: no sample at \(sampleFile.path); run scripts/screenshots.sh")
            return store
        }
        let result = PlaceResult(id: 0, name: "Fremantle", detail: "Western Australia, Australia", kind: "suburb",
                                 boundary: place.boundary, area: 0, osmId: 11689400)
        let sample = SampleExplorer.make(place: result, ways: place.ways, home: SampleExplorer.fremantleHome, now: now)
        store.save(sample.cities)
        store.flush()
        for walk in sample.walks { store.save(walk) }
        // Found on the walks, a few days apart, the newest first in the book.
        let ends = sample.walks.compactMap(\.endedAt)
        let found = LoreLibrary.all.filter { $0.suburb == secretsArea }.sorted { $0.id < $1.id }.prefix(foundCount)
        var stickers: [String: Date] = [:]
        for (i, entry) in found.enumerated() where !ends.isEmpty {
            stickers[entry.id] = ends[min(ends.count - 1, i * ends.count / foundCount)]
        }
        store.save(stickers: stickers)
        return store
    }

    /// Opens the tab (and part of the progress page) the screenshot is of.
    static func configure(_ navigation: AppNavigation) {
        switch screen {
        case .secrets: navigation.tab = .secrets
        case .progress: navigation.showProgress(.level)
        case .quests: navigation.showProgress(.quests)
        case .walks: navigation.tab = .walks
        case .settings: navigation.tab = .settings
        case .map, .recap, nil: navigation.tab = .map
        }
    }

    /// Where "you" are on the map: home again, at the end of today's walk.
    static var location: CLLocation {
        let home = SampleExplorer.fremantleHome
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now
        )
    }
}
#endif
