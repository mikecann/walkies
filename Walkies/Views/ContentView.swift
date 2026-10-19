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

    var body: some View {
        @Bindable var model = model

        FogMapView(
            city: model.selectedCity,
            fresh: model.selectedFreshTiles,
            revision: model.tilesRevision,
            path: model.activePath,
            focus: focus,
            tilted: model.tilted3D,
            handle: mapHandle,
            stickers: stickerPins,
            onSelectSticker: { openSticker = LoreLibrary.entry(id: $0) }
        )
        .overlay {
            CloudLayer(field: model.cloudField, key: model.cloudKey, handle: mapHandle)
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
                    if !model.stickersHere.isEmpty {
                        HexBadge(icon: .art("icon-book"), label: "Secrets") { showingStickers = true }
                    }
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
                VStack(spacing: 10) {
                    if model.selectedCity != nil {
                        HexBadge(icon: .art("icon-map"), fill: .badgeGreen, label: "Whole place") { focus.send(.city) }
                    }
                    HexBadge(icon: .symbol("location.fill"), fill: .badgeTeal, label: "Where am I") { focus.send(.user) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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
        .sheet(item: $model.finishedWalk) { walk in
            WalkSummaryView(walk: walk, city: model.selectedCity)
        }
        .sensoryFeedback(.success, trigger: model.revealCount)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.saveNow() }
            if phase == .active {
                model.finishStaleAutoWalk()
                sync.schedule()
            }
        }
        .task {
            model.tracker.requestPermissionIfNeeded()
        }
    }
}

extension ContentView {
    private var secretsCount: (found: Int, total: Int)? {
        let here = model.stickersHere
        guard !here.isEmpty else { return nil }
        return (here.filter { model.foundStickers[$0.entry.id] != nil }.count, here.count)
    }

    /// Found stickers in the selected city, pinned on the tile they were under.
    private var stickerPins: [StickerPin] {
        guard let city = model.selectedCity else { return [] }
        return model.stickersHere
            .filter { model.foundStickers[$0.entry.id] != nil }
            .map { StickerPin(id: $0.entry.id, coordinate: city.grid.projection.unproject(city.grid.centre(of: $0.hex))) }
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
        if let walk = model.activeWalk {
            VStack(spacing: 12) {
                HStack {
                    TimelineView(.periodic(from: walk.startedAt, by: 1)) { _ in
                        Stat(value: Format.duration(walk.duration), label: "Time")
                    }
                    Stat(value: Format.distance(walk.distance), label: "Distance")
                    Stat(value: "\(walk.newTiles)", label: "New tiles", tint: .walkiesOrange)
                }
                if walk.isAutomatic {
                    Label("Recording this walk automatically", systemImage: "location.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.ink.opacity(0.6))
                } else {
                    Button("End walk") { model.endWalk() }
                        .buttonStyle(StickerButtonStyle())
                }
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
            HStack(spacing: 12) {
                Image("icon-paw")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Always on").font(.headline)
                    Text(model.newTilesToday == 0
                         ? "Just head out. Your walk will be picked up."
                         : "\(model.newTilesToday) new \(model.newTilesToday == 1 ? "tile" : "tiles") today")
                        .font(.subheadline)
                        .foregroundStyle(Color.ink.opacity(0.65))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .stickerCard(in: .rect(cornerRadius: 26))
        } else {
            Button(action: onStart) {
                HStack(spacing: 8) {
                    Image("icon-paw").resizable().scaledToFit().frame(width: 26, height: 26)
                    Text("Start walk").font(.title3.weight(.semibold))
                }
            }
            .buttonStyle(StickerButtonStyle())
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
