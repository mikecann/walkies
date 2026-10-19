import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCities = false
    @State private var focus = MapFocusRequest()

    var body: some View {
        @Bindable var model = model

        FogMapView(
            city: model.selectedCity,
            fresh: model.selectedFreshTiles,
            revision: model.tilesRevision,
            path: model.activePath,
            focus: focus
        )
        .ignoresSafeArea()
        .safeAreaInset(edge: .top) {
            CityCard(city: model.selectedCity) { showingCities = true }
                .padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 10) {
                    if model.selectedCity != nil {
                        MapButton(systemImage: "map") { focus.send(.city) }
                    }
                    MapButton(systemImage: "location.fill") { focus.send(.user) }
                }
                WalkControls {
                    model.startWalk()
                    focus.send(.user)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showingCities) {
            CitiesView()
        }
        .sheet(item: $model.finishedWalk) { walk in
            WalkSummaryView(walk: walk, city: model.selectedCity)
        }
        .sensoryFeedback(.success, trigger: model.revealCount)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.saveNow() }
        }
        .task {
            model.tracker.requestPermissionIfNeeded()
        }
    }
}

private struct MapButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassCard(in: .circle, interactive: true)
    }
}

struct CityCard: View {
    let city: City?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let city {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(city.name).font(.headline)
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(city.visited.count) of \(city.tiles.count) tiles")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                            Spacer()
                            Text(city.progress.percentText)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        ProgressBar(value: city.progress)
                    }
                } else {
                    HStack {
                        Label("Add a city to start exploring", systemImage: "plus.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
            .padding(16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(in: .rect(cornerRadius: 24), interactive: true)
        .animation(.snappy, value: city?.visited.count)
    }
}

struct WalkControls: View {
    @Environment(AppModel.self) private var model
    let onStart: () -> Void

    var body: some View {
        if let walk = model.activeWalk {
            VStack(spacing: 14) {
                HStack {
                    TimelineView(.periodic(from: walk.startedAt, by: 1)) { _ in
                        Stat(value: Format.duration(walk.duration), label: "Time")
                    }
                    Stat(value: Format.distance(walk.distance), label: "Distance")
                    Stat(value: "\(walk.newTiles)", label: "New tiles", tint: .walkiesOrange)
                }
                Button {
                    model.endWalk()
                } label: {
                    Text("End walk")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .prominentButton()
                .tint(.red)
                .controlSize(.large)
            }
            .padding(16)
            .glassCard(in: .rect(cornerRadius: 28))
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
                .prominentButton()
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .glassCard(in: .rect(cornerRadius: 28))
        } else {
            Button(action: onStart) {
                Label("Start walk", systemImage: "pawprint.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .prominentButton()
            .controlSize(.large)
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
