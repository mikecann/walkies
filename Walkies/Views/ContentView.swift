import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncEngine.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCities = false
    @State private var showingSettings = false
    @State private var showingStickers = false
    @State private var openSticker: LoreEntry?
    @State private var focus = MapFocusRequest()
    @State private var mapHandle = MapHandle()
    /// A suburb next door you've tapped, waiting for you to confirm adding it.
    @State private var pickedNeighbour: PlaceResult?
    /// What's happening while a suburb from the map is being added.
    @State private var addingStatus: String?
    @State private var addingError: String?

    var body: some View {
        @Bindable var model = model

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
            onSelectSticker: { openSticker = LoreLibrary.entry(id: $0) },
            neighbours: addingStatus == nil ? model.neighbours : [],
            onPickNeighbour: { pickedNeighbour = $0 }
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
        .ignoresSafeArea()
        .safeAreaInset(edge: .top) {
            HStack(alignment: .top) {
                PlaceChip(city: model.selectedCity, secrets: secretsCount) { showingCities = true }
                Spacer(minLength: 12)
                VStack(spacing: 10) {
                    HexBadge(icon: .art("icon-gear"), label: "Settings") { showingSettings = true }
                    HexBadge(icon: .art("icon-book"), label: "Secrets") { showingStickers = true }
                }
            }
            .padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 10) {
                WalkControls {
                    model.startWalk()
                    focus.send(.user)
                }
                HexBadge(icon: .symbol("location.fill"), fill: .badgeTeal, label: "Where am I") { focus.send(.user) }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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
        .sheet(isPresented: $showingCities) {
            CitiesView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingStickers) {
            StickerBookView()
        }
        .sheet(item: $openSticker) { entry in
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
        .fullScreenCover(item: $model.recap) { recap in
            CelebrationView(
                recap: recap,
                others: model.cities.filter { city in !recap.after.contains { $0.id == city.id } },
                tilted: model.tilted3D
            )
        }
        .sensoryFeedback(.success, trigger: model.revealCount)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.saveNow() }
            if phase == .active {
                model.finishStaleAutoWalk()
                model.refreshNeighbours()
                sync.schedule()
            }
        }
    }
}

extension ContentView {
    /// Fetches a neighbouring suburb's streets and adds it, sharing the hex grid with
    /// your places next door so the tiles line up along the border.
    private func add(_ place: PlaceResult) {
        addingStatus = "Getting \(place.name) ready…"
        Task {
            do {
                let city = try await CityBuilder.build(from: place, walks: model.walks, near: model.cities) { addingStatus = $0 }
                model.add(city)
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

/// The place you're exploring, kept small: name and percentage. Tap it for the
/// details and to switch places.
struct PlaceChip: View {
    let city: City?
    /// Found and total secrets here, when the place has any.
    let secrets: (found: Int, total: Int)?
    let onChangePlace: () -> Void

    @State private var open = false

    var body: some View {
        if let city {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(city.name).font(.headline).lineLimit(1).fixedSize()
                        Text(city.progress.percentText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.walkiesOrange)
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.ink.opacity(0.5))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if open {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressBar(value: city.progress)
                        Text("\(city.visited.count) of \(city.tiles.count) tiles explored")
                            .font(.subheadline)
                        if let secrets {
                            Text("\(secrets.found) of \(secrets.total) secrets found")
                                .font(.subheadline)
                        }
                        Button("Change place", action: onChangePlace)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.burnt)
                            .padding(.top, 2)
                    }
                    .foregroundStyle(Color.ink.opacity(0.75))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(minWidth: open ? 250 : nil, alignment: .leading)
            .stickerCard(in: .rect(cornerRadius: open ? 22 : 24))
            .animation(.snappy, value: city.visited.count)
        } else {
            Button(action: onChangePlace) {
                Label("Add a place to explore", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .stickerCard(in: .capsule)
        }
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
