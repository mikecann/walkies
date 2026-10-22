import ChefKit
import SwiftUI

/// The app once you're in: a tab for each page along the bottom, with the map first.
/// Sheets that can come up over any tab, and the end-of-walk celebration, present from here.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = AppNavigation()
    /// The recap on screen. Every recap plays from here, once any sheet is out of the way.
    @State private var shownRecap: WalkRecap?

    var body: some View {
        @Bindable var navigation = navigation

        TabView(selection: $navigation.tab) {
            Tab(value: AppNavigation.Tab.map) {
                MapScreen()
                    .tint(.burnt)
            } label: {
                tabLabel("Map", art: "icon-map", tab: .map)
            }
            Tab(value: AppNavigation.Tab.secrets) {
                StickerBookView()
                    .tint(.burnt)
            } label: {
                tabLabel("Secrets", art: "icon-book", tab: .secrets)
            }
            Tab(value: AppNavigation.Tab.progress) {
                ProgressPage()
                    .tint(.burnt)
            } label: {
                tabLabel("Progress", art: "progress-shell", tab: .progress)
            }
            // The orange badge, like the dot on the shells chip, while a level-up reward waits.
            .badge(model.pendingPicks.count)
            Tab(value: AppNavigation.Tab.walks) {
                NavigationStack { WalkHistoryView() }
                    .tint(.burnt)
            } label: {
                tabLabel("Walks", art: "icon-walk", tab: .walks)
            }
            Tab(value: AppNavigation.Tab.settings) {
                SettingsView()
                    .tint(.burnt)
            } label: {
                tabLabel("Settings", art: "icon-gear", tab: .settings)
            }
        }
        .tint(.walkiesOrange)
        .environment(navigation)
        .alert("Team membership changed", isPresented: Binding(get: { model.teamNotice != nil }, set: { if !$0 { model.teamNotice = nil } })) {
            Button("OK") { model.teamNotice = nil }
        } message: { Text(model.teamNotice ?? "") }
        .sheet(isPresented: $navigation.showingPlaces, onDismiss: showRecapIfReady) {
            MapsAndPlacesView()
        }
        .sheet(item: $navigation.openSecret, onDismiss: showRecapIfReady) { entry in
            LoreCardView(entry: entry, foundAt: model.foundStickers[entry.id])
        }
        .overlay {
            // A separate host for the new-sticker pop-up, so it doesn't fight the other sheets.
            Color.clear
                .allowsHitTesting(false)
                .sheet(item: newSticker) { entry in
                    LoreCardView(entry: entry, foundAt: model.foundStickers[entry.id], isNew: true)
                }
        }
        .sensoryFeedback(.success, trigger: model.stickerQueue.count) { old, new in new > old }
        .fullScreenCover(item: Binding(get: { shownRecap }, set: { shownRecap = $0; if $0 == nil { model.recap = nil } })) { recap in
            CelebrationView(
                recap: recap,
                others: model.cities.filter { city in !recap.after.contains { $0.id == city.id } },
                tilted: model.tilted3D
            )
            .environment(navigation)
        }
        .onChange(of: model.recap?.id, initial: true) {
            // A cover can't go over a sheet from here. A walk that's just ended waits for
            // the sheet to close; rewatching one from Walks closes it and plays over the map.
            if model.recap == nil {
                shownRecap = nil
            } else if !sheetOpen {
                shownRecap = model.recap
            } else if model.recap?.isRewatch == true {
                navigation.showingPlaces = false
                navigation.openSecret = nil
            }
        }
        .sheet(isPresented: Binding(get: { model.pendingTeamInvite != nil }, set: { if !$0 { model.pendingTeamInvite = nil } }), onDismiss: showRecapIfReady) {
            JoinTeamView(initialCode: model.pendingTeamInvite ?? "")
        }
        .task { await account.refreshProfile() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                await sync.sync()
            }
        }
        .sensoryFeedback(.success, trigger: model.revealCount)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { model.saveNow(waiting: true) }
            if phase == .active {
                model.placeYouOnNextFix = true
                model.finishStaleAutoWalk()
                model.refreshNeighbours()
                sync.schedule()
            }
        }
    }

    private func tabLabel(_ title: String, art: String, tab: AppNavigation.Tab) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: TabArt.icon(art, selected: navigation.tab == tab))
                .renderingMode(.original)
        }
    }

    private var sheetOpen: Bool {
        navigation.showingPlaces || navigation.openSecret != nil || model.pendingTeamInvite != nil
    }

    /// Plays a recap that arrived while a sheet was up, now it's gone.
    private func showRecapIfReady() {
        guard !sheetOpen, shownRecap == nil, let recap = model.recap else { return }
        shownRecap = recap
    }

    /// The first sticker waiting to pop up. Closing it moves on to the next.
    private var newSticker: Binding<LoreEntry?> {
        Binding {
            model.stickerQueue.first
        } set: { value in
            if value == nil, !model.stickerQueue.isEmpty {
                model.stickerQueue.removeFirst()
            }
        }
    }
}

/// The app's own art for the tab bar, in colour rather than as a silhouette, shrunk to
/// tab size. The tabs you're not on are faded, and the selected one's title goes orange.
enum TabArt {
    private static var cache: [String: UIImage] = [:]

    static func icon(_ name: String, selected: Bool) -> UIImage {
        let key = "\(name)-\(selected)"
        if let cached = cache[key] { return cached }
        guard let art = UIImage(named: name) else { return UIImage() }
        let size = CGSize(width: 28, height: 28)
        let fit = min(size.width / art.size.width, size.height / art.size.height)
        let drawn = CGSize(width: art.size.width * fit, height: art.size.height * fit)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            art.draw(
                in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height),
                blendMode: .normal, alpha: selected ? 1 : 0.55
            )
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }

    /// The tab bar in cream, with the reward badge in the app's orange.
    static func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.cream)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.ink.opacity(0.6))]
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor.walkiesOrange]
            layout.normal.badgeBackgroundColor = .walkiesOrange
            layout.selected.badgeBackgroundColor = .walkiesOrange
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

/// The map with the clouds over it, the chips top left, and the walk controls along
/// the bottom, above the tab bar.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var focus = MapFocusRequest()
    @State private var mapHandle = MapHandle()
    /// A suburb next door you've tapped, waiting for you to confirm adding it.
    @State private var pickedNeighbour: PlaceResult?
    /// What's happening while a suburb from the map is being added.
    @State private var addingStatus: String?
    @State private var addingError: String?
    /// Where the buttons over the map are, so the neighbour labels keep out from under them.
    @State private var buttonFrames: [String: CGRect] = [:]

    var body: some View {
        FogMapView(
            cities: model.cities,
            selectedID: model.selectedCityID,
            flyID: model.flyToSelected,
            fresh: model.freshTiles,
            revision: model.tilesRevision,
            path: model.activePath,
            focus: focus,
            tilted: model.tilted3D,
            handle: mapHandle,
            stickers: stickerPins,
            onSelectSticker: { navigation.openSecret = LoreLibrary.entry(id: $0) },
            neighbours: addingStatus == nil ? model.neighbours : [],
            onPickNeighbour: { pickedNeighbour = $0 },
            buttons: Array(buttonFrames.values)
        )
        .overlay {
            CloudLayer(field: model.cloudField, key: model.cloudKey, handle: mapHandle, walkTiles: walkTiles)
        }
        .overlay(alignment: .top) {
            // Keeps the status bar readable over dark water.
            LinearGradient(colors: [Color.cream.opacity(0.85), Color.cream.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
                .allowsHitTesting(false)
        }
        // Edge to edge, under the status bar and the tab bar (which floats over it on
        // newer iOS). MapKit keeps its legal link inside the safe area, above the tabs.
        .ignoresSafeArea()
        .safeAreaInset(edge: .top) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    PlaceChip(city: model.selectedCity, secrets: secretsCount) { navigation.showingPlaces = true }
                    ShellsChip { navigation.showProgress(.level) }
                }
                .mapButton("top leading", in: $buttonFrames)
                Spacer(minLength: 12)
                // Long-press: a screenshot of the map and a voice note, straight away.
                HexBadge(icon: .art("icon-idea"), label: "Suggest a feature", onLongPress: { ChefKit.report() }) {
                    ChefKit.present()
                }
                .mapButton("top trailing", in: $buttonFrames)
            }
            .padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if model.secretsAlreadyWalked > 0 {
                    NewSecretsBadge(count: model.secretsAlreadyWalked) {
                        model.secretsAlreadyWalked = 0
                        navigation.tab = .secrets
                    } onClose: {
                        model.secretsAlreadyWalked = 0
                    }
                    .mapButton("secrets", in: $buttonFrames)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                HStack(alignment: .bottom, spacing: 10) {
                    WalkControls {
                        model.startWalk()
                        focus.send(.user)
                    }
                    .mapButton("walk", in: $buttonFrames)
                    HexBadge(icon: .symbol("location.fill"), fill: .badgeTeal, label: "Where am I") { focus.send(.user) }
                        .mapButton("where am I", in: $buttonFrames)
                }
            }
            .animation(.snappy, value: model.secretsAlreadyWalked > 0)
            .padding(.horizontal)
            // Clear of MapKit's legal link along the bottom of the map.
            .padding(.bottom, 26)
        }
        .overlay {
            if let addingStatus {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(addingStatus).font(.headline)
                    Text("This can take up to a minute.")
                        .font(.caption)
                        .foregroundStyle(Color.ink.opacity(0.6))
                }
                .padding(28)
                .stickerCard(in: .rect(cornerRadius: 24))
            }
        }
        .confirmationDialog(
            pickedNeighbour.map { "Add \($0.name)?" } ?? "",
            isPresented: Binding(get: { pickedNeighbour != nil }, set: { if !$0 { pickedNeighbour = nil } }),
            titleVisibility: .visible,
            presenting: pickedNeighbour
        ) { place in
            Button("Add \(place.name)") { add(place) }
            Button("Not now", role: .cancel) {}
        } message: { place in
            Text("\(place.kind.capitalized) · \(Format.area(place.area)). It'll go under the clouds next to your other places, and any walks you've already done there count.")
        }
        .alert("Couldn't add it", isPresented: Binding(get: { addingError != nil }, set: { if !$0 { addingError = nil } })) {
            Button("OK") {}
        } message: {
            Text(addingError ?? "")
        }
        .task {
            // `-perfRun`: fly the map about and print how smoothly it drew.
            if PerfRun.requested { await PerfRun(handle: mapHandle, model: model).run() }
        }
        .overlay(alignment: .bottomLeading) {
            // Just above the Maps logo, clear of the chips and buttons.
            if PerfOverlay.requested { PerfOverlay().padding(.leading, 10).padding(.bottom, 32) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Open on where you are, in whichever of your places that is.
            if phase == .active { focus.send(.arrive) }
        }
    }
}

extension MapScreen {
    /// Fetches a neighbouring suburb's streets and adds it on the world grid.
    private func add(_ place: PlaceResult) {
        addingStatus = "Getting \(place.name) ready…"
        Task {
            do {
                try await model.addPlace(place) { addingStatus = $0 }
            } catch {
                addingError = "Couldn't load the streets for \(place.name). OpenStreetMap might be busy, so try again in a minute."
            }
            addingStatus = nil
        }
    }

    private var secretsCount: (found: Int, total: Int)? {
        let here = model.stickersHere
        guard !here.isEmpty else { return nil }
        return (here.filter { model.foundStickers[$0.entry.id] != nil }.count, here.count)
    }

    /// Found secrets in every place, pinned on the tile they were under. Tap one to read it again.
    private var stickerPins: [StickerPin] {
        model.cities.flatMap { city in
            (city.stickers ?? [:])
                .filter { model.foundStickers[$0.key] != nil }
                .sorted { $0.key < $1.key }
                .map { StickerPin(id: $0.key, coordinate: city.grid.projection.unproject(city.grid.centre(of: $0.value))) }
        }
    }

    /// Tiles uncovered on this walk, for the honeycomb that shows while you drag the map.
    private var walkTiles: Set<CloudField.Tile> {
        Set(model.cities.flatMap { city in (model.freshTiles[city.id] ?? []).map { CloudField.Tile(grid: city.grid, hex: $0) } })
    }
}

/// The place you're exploring, kept small: your head, the place and percentage.
/// Tap it for the details and to change place.
struct PlaceChip: View {
    @Environment(AppModel.self) private var model
    @Environment(Account.self) private var account
    let city: City?
    /// Found and total secrets here, when the place has any.
    let secrets: (found: Int, total: Int)?
    let onChangePlace: () -> Void

    @State private var open = false

    private var heads: [Head] { [Head.you(account, teams: model.teams)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    AvatarStack(heads: heads)
                    if model.worldGridResetPending {
                        Text("Rebuilding places").font(.headline).lineLimit(1)
                        ProgressView().controlSize(.small)
                    } else {
                        Text(city?.name ?? "Places").font(.headline).lineLimit(1)
                    }
                    if let city {
                        Text(city.progress.percentText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.walkiesOrange)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.ink.opacity(0.5))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(city.map { "\($0.name), \($0.progress.percentText.replacingOccurrences(of: "%", with: " percent"))" } ?? "Places")
            .accessibilityHint(open ? "Hides the details" : "Shows your progress")

            if open {
                VStack(alignment: .leading, spacing: 10) {
                    if model.worldGridResetPending {
                        Text("Your places are moving onto the new map. It needs internet and can take a minute or two.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let city {
                        ProgressBar(value: city.progress)
                        Text("\(city.visited.count) of \(city.tiles.count) tiles explored")
                            .font(.subheadline)
                        if let secrets {
                            Text("\(secrets.found) of \(secrets.total) secrets found")
                                .font(.subheadline)
                        }
                    }
                    Button("Change place", action: onChangePlace)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.burnt)
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                }
                .foregroundStyle(Color.ink.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(minWidth: open ? 250 : nil, alignment: .leading)
        .stickerCard(in: .rect(cornerRadius: open ? 22 : 24))
        .animation(.snappy, value: city?.visited.count)
    }
}

struct WalkControls: View {
    @Environment(AppModel.self) private var model
    let onStart: () -> Void

    var body: some View {
        if model.autoWalkPending {
            PendingWalkBadge(distance: model.pendingWalkDistance)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let walk = model.activeWalk {
            VStack(spacing: 12) {
                HStack {
                    TimelineView(.periodic(from: walk.startedAt, by: 1)) { _ in
                        Stat(value: Format.duration(walk.duration), label: "Time")
                    }
                    Stat(value: Format.distance(walk.distance), label: "Distance")
                    Stat(value: "\(walk.newTiles)", label: "New tiles", tint: .walkiesOrange)
                }
                Button("End walk") {
                    walk.isAutomatic ? model.endAutoWalk() : model.endWalk()
                }
                .buttonStyle(StickerButtonStyle())
            }
            .padding(14)
            .stickerCard(in: .rect(cornerRadius: 26))
        } else if model.tracker.isDenied {
            VStack(spacing: 10) {
                Text("Walkies needs your location to uncover tiles.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(StickerButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .stickerCard(in: .rect(cornerRadius: 26))
        } else if model.alwaysOn {
            // Nothing to press: walks get picked up by themselves. Just keep the
            // buttons on the right where they are.
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        } else {
            Button(action: onStart) {
                HStack(spacing: 8) {
                    Image("icon-walk").resizable().scaledToFit().frame(width: 26, height: 26)
                    Text("Start walk").font(.title3.weight(.semibold))
                }
            }
            .buttonStyle(StickerButtonStyle())
        }
    }
}

/// Secrets that turned up under tiles you'd already walked, all at once. Tap to see
/// them in the book.
private struct NewSecretsBadge: View {
    let count: Int
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image("icon-book").resizable().scaledToFit().frame(width: 26, height: 26)
                    Text(count == 1 ? "A new secret in places you've walked" : "\(count) new secrets in places you've walked")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                }
                .padding(.leading, 8)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(PressScale())
            .accessibilityHint("Opens your secrets book")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ink.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.trailing, 4)
        .stickerCard(in: .rect(cornerRadius: 20))
    }
}

private extension View {
    /// Tells the map where this button sits, so the labels on the map keep clear of it.
    func mapButton(_ key: String, in frames: Binding<[String: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.wrappedValue[key] = $0 }
            .onDisappear { frames.wrappedValue[key] = nil }
    }
}

/// A walk that might just be GPS wandering about at home: a small shoe and how far
/// you've got. Tap it and it says what that means, then shrinks back.
private struct PendingWalkBadge: View {
    let distance: Double
    @State private var explaining = false

    var body: some View {
        Button {
            withAnimation(.snappy) { explaining.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image("icon-walk").resizable().scaledToFit().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(explaining ? "Walk pending, \(Int(distance)) m so far" : "\(Int(distance)) m")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if explaining {
                        Text("Counts once you're \(Int(AppModel.autoWalkConfirmDistance)) m from where you started")
                            .font(.caption)
                            .foregroundStyle(Color.ink.opacity(0.6))
                    }
                }
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .stickerCard(in: .rect(cornerRadius: 20))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Walk pending, \(Int(distance)) metres so far")
        .task(id: explaining) {
            guard explaining else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.snappy) { explaining = false }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .ink

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(tint == .ink ? Color.ink.opacity(0.6) : tint)
        }
        .frame(maxWidth: .infinity)
    }
}
