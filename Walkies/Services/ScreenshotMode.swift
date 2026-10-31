#if DEBUG
import CoreLocation
import Foundation

/// App Store screenshots (scripts/screenshots.sh): `-WalkiesScreen <screen>` opens
/// Walkies straight on that screen as a made-up explorer a few weeks into Fremantle, WA,
/// who's also had a long weekend in Busselton, where the secrets are. It's built from
/// `appstore/sample/*.json`, which the script copies into the app's Application Support
/// under ScreenshotSamples. Everything lives in a scratch folder that's made again on
/// every launch, the saved session isn't read, and nothing syncs, so it never shows or
/// touches anyone's real walks. Debug builds only.
enum ScreenshotMode {
    enum Screen: String, CaseIterable {
        case map, recap, secrets, progress, quests, walks, settings
    }

    static let screen: Screen? = LaunchArguments.value(after: "-WalkiesScreen").flatMap(Screen.init(rawValue:))
    static var isOn: Bool { screen != nil }

    static let samples = URL.applicationSupportDirectory.appending(path: "ScreenshotSamples", directoryHint: .isDirectory)
    private static let root = URL.temporaryDirectory.appending(path: "WalkiesScreenshots", directoryHint: .isDirectory)

    /// What the made-up explorer is called.
    static let explorerName = "Sam"

    /// How far up the map opens, in metres (1,500 normally). `-WalkiesMapDistance 20000`
    /// opens further out, to see the world's clouds round the places.
    static let mapDistance = LaunchArguments.value(after: "-WalkiesMapDistance").flatMap(Double.init) ?? 4_000.0

    /// The secrets book opens with this area showing: the one the Busselton weekend found.
    static let secretsArea = "Busselton"

    /// A fresh store holding the sample, or an empty one if the sample files are missing.
    static func makeStore(now: Date = .now) -> Store {
        try? FileManager.default.removeItem(at: root)
        let store = Store(root: root)
        func load(_ name: String) -> CachedPlaceData? {
            try? JSONDecoder().decode(CachedPlaceData.self, from: Data(contentsOf: samples.appending(path: "\(name).json")))
        }
        guard let fremantle = load("fremantle") else {
            print("ScreenshotMode: no samples in \(samples.path); run scripts/screenshots.sh")
            return store
        }
        // Fremantle first, so it's the place the map opens on.
        var trips = [SampleExplorer.Trip(
            place: PlaceResult(id: 0, name: "Fremantle", detail: "Western Australia, Australia", kind: "suburb",
                               boundary: fremantle.boundary, area: 0, osmId: 11689400),
            ways: fremantle.ways, home: SampleExplorer.fremantleHome, walks: SampleExplorer.fremantleWalks
        )]
        if let busselton = load("busselton") {
            trips.append(SampleExplorer.Trip(
                place: PlaceResult(id: 1, name: "Busselton", detail: "Western Australia, Australia", kind: "suburb",
                                   boundary: busselton.boundary, area: 0, osmId: 11688699),
                ways: busselton.ways, home: SampleExplorer.busseltonStay, walks: SampleExplorer.busseltonWalks,
                targets: SampleExplorer.busseltonTargets
            ))
        }
        let sample = SampleExplorer.make(trips, now: now)
        store.save(sample.cities)
        store.flush()
        for walk in sample.walks { store.save(walk) }
        store.save(stickers: sample.secrets)
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

    /// Where "you" are: out in the middle of Fremantle, so the map has clouds all round.
    /// The front door's near the edge, where the next suburb has none. screenshots.sh
    /// sets the simulator's location here too, which is what the map opens on.
    static var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: -32.0545, longitude: 115.7515),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: .now
        )
    }
}
#endif
