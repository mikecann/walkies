import MapKit
import SwiftUI

struct WalkHistoryView: View {
    @Environment(AppModel.self) private var model

    private var months: [(date: Date, walks: [Walk])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.walks) {
            calendar.dateInterval(of: .month, for: $0.startedAt)?.start ?? $0.startedAt
        }
        return grouped.keys.sorted(by: >).map { date in
            (date, grouped[date, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    if let steps = model.stepCounter.today, model.countSteps {
                        LabeledContent("Steps today", value: steps.formatted())
                            .font(.headline)
                    }
                    Text("Every walk adds up")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                    WalkStats(items: [
                        ("Walks", "\(model.walks.count)"),
                        ("Distance", Format.distance(model.walks.reduce(0) { $0 + $1.distance })),
                        ("Time", Format.duration(model.walks.reduce(0) { $0 + $1.duration })),
                        ("Tiles uncovered", "\(model.walks.reduce(0) { $0 + $1.newTiles })")
                    ])
                }
                .padding(20)
                .stickerCard(in: RoundedRectangle(cornerRadius: 24))

                if model.walks.isEmpty {
                    ContentUnavailableView(
                        "No walks yet", systemImage: "shoeprints.fill",
                        description: Text("Head out for a walk and you'll find it here when you're done.")
                    )
                }

                ForEach(months, id: \.date) { month in
                    Section {
                        ForEach(month.walks) { walk in
                            NavigationLink {
                                WalkDetailView(walk: walk)
                            } label: {
                                WalkHistoryRow(walk: walk)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(month.date.formatted(.dateTime.month(.wide).year()))
                            .font(.system(.title3, design: .rounded, weight: .heavy))
                            .padding(.top, 4)
                    }
                }
            }
            .padding()
        }
        .background(Color.cream)
        .foregroundStyle(Color.ink)
        .task { await model.refreshStepsToday() }
        .navigationTitle("Past walks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WalkHistoryRow: View {
    let walk: Walk

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RouteSketch(points: walk.points)
                .frame(width: 56, height: 56)
                .padding(8)
                .background(Color.sand.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(walk.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                Text(walk.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(Format.distance(walk.distance))
                        Text(Format.duration(walk.duration))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.distance(walk.distance))
                        Text(Format.duration(walk.duration))
                    }
                }
                .font(.subheadline.weight(.semibold))
                Text("\(walk.newTiles) new \(walk.newTiles == 1 ? "tile" : "tiles")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let steps = walk.steps {
                    Text("\(steps.formatted()) steps").font(.subheadline.weight(.semibold))
                }
                if walk.isAutomatic {
                    Text("Always on")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.badgeGreen.opacity(0.4), in: .capsule)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.badgeTeal)
                .padding(.top, 6)
        }
        .padding(16)
        .stickerCard(in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Keep the route's proportions in local metres, with north at the top. A straight
/// line or a single fix still fits without dividing by zero.
private struct RouteSketch: View {
    let points: [TrackPoint]

    var body: some View {
        GeometryReader { geometry in
            let coordinates = points.map(\.coordinate)
            if let first = coordinates.first {
                let projected = coordinates.map(LocalProjection(origin: first).project)
                let minX = projected.map(\.x).min() ?? 0
                let maxX = projected.map(\.x).max() ?? 0
                let minY = projected.map(\.y).min() ?? 0
                let maxY = projected.map(\.y).max() ?? 0
                let scale = min(geometry.size.width, geometry.size.height) / max(maxX - minX, maxY - minY, 1)
                let drawing = projected.map { point in
                    CGPoint(
                        x: geometry.size.width / 2 + (point.x - (minX + maxX) / 2) * scale,
                        y: geometry.size.height / 2 - (point.y - (minY + maxY) / 2) * scale
                    )
                }
                Path { path in
                    if let start = drawing.first {
                        path.move(to: start)
                        for point in drawing.dropFirst() { path.addLine(to: point) }
                    }
                }
                .stroke(Color.burnt, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let start = drawing.first {
                    Circle().fill(Color.burnt).frame(width: 5, height: 5).position(start)
                }
            } else {
                Image(systemName: "shoeprints.fill")
                    .foregroundStyle(Color.burnt.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(3)
    }
}

struct WalkDetailView: View {
    let walk: Walk
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation

    private var secrets: [LoreEntry] {
        guard let end = walk.endedAt else { return [] }
        return LoreLibrary.all.filter { entry in
            guard let date = model.foundStickers[entry.id] else { return false }
            return date >= walk.startedAt && date <= end
        }.sorted { a, b in
            let x = model.foundStickers[a.id] ?? .distantPast
            let y = model.foundStickers[b.id] ?? .distantPast
            return x == y ? a.id < b.id : x < y
        }
    }

    var body: some View {
        let coordinates = walk.points.map { $0.coordinate.cl }

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if coordinates.isEmpty {
                    ContentUnavailableView(
                        "No route saved", systemImage: "map",
                        description: Text("This walk's stats are here, but it hasn't got any route points.")
                    )
                    .frame(height: 260)
                    .stickerCard(in: RoundedRectangle(cornerRadius: 24))
                } else {
                    Map(initialPosition: .region(region(for: coordinates))) {
                        // A light halo and a dark edge under the teal, so it shows over grass and water.
                        MapPolyline(coordinates: coordinates)
                            .stroke(TrailContrast.halo.color(TrailContrast.haloAlpha), style: StrokeStyle(lineWidth: 5 + TrailContrast.haloExtra, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: coordinates)
                            .stroke(TrailContrast.edge.color(TrailContrast.edgeAlpha), style: StrokeStyle(lineWidth: 5 + TrailContrast.edgeExtra, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: coordinates)
                            .stroke(TrailContrast.teal.color(1), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        if let first = coordinates.first {
                            Annotation("Start", coordinate: first) {
                                Circle().fill(Color.badgeGreen)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                            }
                        }
                        if coordinates.count > 1, let last = coordinates.last {
                            Annotation("Finish", coordinate: last) {
                                Circle().fill(Color.burnt)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                            }
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white, lineWidth: 3))
                    .accessibilityLabel("Route for this walk")
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(walk.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                    Text(walk.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let steps = walk.steps { Text("\(steps.formatted()) steps").font(.headline) }
                    WalkStats(items: [
                        ("Distance", Format.distance(walk.distance)),
                        ("Time", Format.duration(walk.duration)),
                        ("New tiles", "\(walk.newTiles)"),
                        ("Recording", walk.isAutomatic ? "Always on" : "Started by you")
                    ])
                }
                .padding(20)
                .stickerCard(in: RoundedRectangle(cornerRadius: 24))

                Button {
                    // Plays over the map, so go there first.
                    navigation.showMap()
                    model.replay(walk)
                } label: {
                    Label("Watch this walk again", systemImage: "play.fill")
                        .font(.headline)
                }
                .buttonStyle(StickerButtonStyle())

                if !secrets.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Secrets found")
                            .font(.system(.title2, design: .rounded, weight: .heavy))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
                            ForEach(secrets) { entry in
                                Button {
                                    navigation.openSecret = entry
                                } label: {
                                    VStack(spacing: 8) {
                                        StickerArt(entry: entry, size: 88)
                                        Text(entry.title)
                                            .font(.caption.weight(.semibold))
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(20)
                    .stickerCard(in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding()
        }
        .background(Color.cream)
        .foregroundStyle(Color.ink)
        .navigationTitle("Your walk")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let south = coordinates.map(\.latitude).min() ?? 0
        let north = coordinates.map(\.latitude).max() ?? south
        let west = coordinates.map(\.longitude).min() ?? 0
        let east = coordinates.map(\.longitude).max() ?? west
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.002, (north - south) * 1.3), longitudeDelta: max(0.002, (east - west) * 1.3))
        )
    }
}

private struct WalkStats: View {
    let items: [(label: String, value: String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 16) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(items[index].value)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .monospacedDigit()
                    Text(items[index].label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
