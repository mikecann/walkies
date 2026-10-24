import SwiftUI
import UIKit

/// Colour and icon for each kind of lore, used until a sticker has its own art.
struct StickerStyle {
    let symbol: String
    let colour: Color
    let label: String

    init(category: String) {
        switch category {
        case "history": (symbol, colour, label) = ("building.columns.fill", Color(red: 0.72, green: 0.45, blue: 0.2), "History")
        case "first-nations": (symbol, colour, label) = ("sun.max.fill", Color(red: 0.8, green: 0.33, blue: 0.18), "First Nations")
        case "nature": (symbol, colour, label) = ("leaf.fill", Color(red: 0.25, green: 0.6, blue: 0.3), "Nature")
        case "the-sea": (symbol, colour, label) = ("water.waves", Color(red: 0.12, green: 0.5, blue: 0.75), "The sea")
        case "odd-records": (symbol, colour, label) = ("star.fill", Color(red: 0.5, green: 0.35, blue: 0.75), "Odd records")
        default: (symbol, colour, label) = ("house.fill", Color.walkiesOrange, "Modern life")
        }
    }
}

/// The sticker itself: its art if it has some, otherwise a badge for its kind.
struct StickerArt: View {
    let entry: LoreEntry
    var size: CGFloat = 96

    var body: some View {
        if let image = UIImage(named: "sticker-\(entry.id)") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.03)
        } else {
            let style = StickerStyle(category: entry.category)
            ZStack {
                Circle().fill(.white)
                Circle().fill(style.colour.gradient).padding(size * 0.06)
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.03)
        }
    }

    /// The same thing as a picture, for map pins and notifications.
    @MainActor
    static func image(for entry: LoreEntry, size: CGFloat) -> UIImage {
        let renderer = ImageRenderer(content: StickerArt(entry: entry, size: size).padding(size * 0.08))
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage ?? UIImage()
    }
}

struct StickerBookView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @AppStorage("secretsBookSort") private var sort = SecretsBook.Sort.nearest
    @AppStorage("secretsBookFilter") private var filter = SecretsBook.Filter.all
    @State private var visibleCount = 6
    @State private var expandedAreas: Set<String> = []

    var body: some View {
        let entries = LoreLibrary.all
        let currentAreaName = SecretsBook.currentAreaName(entries: entries, selectedCityName: model.selectedCity?.name)
        let found = entries.filter { model.foundStickers[$0.id] != nil }.count
        let areas = SecretsBook.sections(
            entries: entries, found: model.foundStickers,
            location: model.lastLocation.map { Coordinate($0.coordinate) },
            places: model.cities, selectedCity: model.selectedCity, sort: sort, filter: filter
        )

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(found) of \(entries.count) secrets found")
                            .font(.system(.title2, design: .rounded, weight: .heavy))
                        ProgressBar(value: entries.isEmpty ? 0 : Double(found) / Double(entries.count))
                        Text("Each one is a story about the area, hidden somewhere under the clouds. Walk new streets to find them.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .modifier(SecretsCover(equipped: model.equipped[.cover]))

                    ForEach(areas.prefix(visibleCount)) { area in
                        areaSection(area)
                            .onAppear {
                                // Append a batch when its last area scrolls into view.
                                if visibleCount < areas.count, area.id == areas.prefix(visibleCount).last?.id {
                                    visibleCount = min(visibleCount + 6, areas.count)
                                }
                            }
                    }

                    if visibleCount < areas.count {
                        HStack(spacing: 8) {
                            ProgressView().tint(Color.burnt)
                            Text("Loading more…").font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if areas.isEmpty {
                        ContentUnavailableView(
                            filter == .found ? "No secrets found yet" : "No secrets to show",
                            systemImage: "book.closed",
                            description: Text(filter == .found
                                ? "Walk new streets to find your first secret."
                                : "Try another filter to see more secrets.")
                        )
                    }
                }
                .padding()
            }
            .id("\(sort.rawValue)-\(filter.rawValue)")
            .background(Color.cream)
            .foregroundStyle(Color.ink)
            .navigationTitle("Secrets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(SecretsBook.Sort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        Picker("Show", selection: $filter) {
                            ForEach(SecretsBook.Filter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            .onChange(of: sort) { visibleCount = 6 }
            .onChange(of: filter) { visibleCount = 6 }
            .onChange(of: currentAreaName, initial: true) {
                if let currentAreaName { expandedAreas.insert(currentAreaName) }
                #if DEBUG
                if ScreenshotMode.isOn { expandedAreas.insert(ScreenshotMode.secretsArea) }
                #endif
            }
        }
    }

    private func areaSection(_ area: SecretsBook.Area) -> some View {
        let isExpanded = expandedAreas.contains(area.id)

        return VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedAreas.remove(area.id)
                    } else {
                        expandedAreas.insert(area.id)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(area.name)
                            .font(.system(.title2, design: .rounded, weight: .heavy))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    HStack {
                        Text("\(area.found) of \(area.total) found")
                        Spacer()
                        if let distance = area.distance {
                            Text("\(Format.distance(distance)) away")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ProgressBar(value: area.progress)
                    if !area.isAdded {
                        Text("Not one of your places yet. Add it from the map to start finding these.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .stickerCard(in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hide secrets in this area" : "Show secrets in this area")

            // Don't build tiles or ask UIKit for their images until this area is opened.
            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 20) {
                    ForEach(area.entries) { entry in
                        let isFound = model.foundStickers[entry.id] != nil
                        Button {
                            navigation.openSecret = entry
                        } label: {
                            StickerTile(entry: entry, found: isFound)
                        }
                        .buttonStyle(.plain)
                        .disabled(!isFound)
                    }
                }
            }
        }
    }
}

private struct StickerTile: View {
    let entry: LoreEntry
    let found: Bool

    var body: some View {
        VStack(spacing: 8) {
            if found {
                StickerArt(entry: entry, size: 88)
            } else if let image = UIImage(named: "sticker-\(entry.id)") {
                // A grey silhouette, like the empty spaces in a sticker album.
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.quaternary)
                    .frame(width: 88, height: 88)
            } else {
                ZStack {
                    Circle().fill(.quaternary)
                    Text("?")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 88, height: 88)
            }
            Text(found ? entry.title : "???")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(found ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LoreCardView: View {
    let entry: LoreEntry
    let foundAt: Date?
    var isNew = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let style = StickerStyle(category: entry.category)
        ScrollView {
            VStack(spacing: 16) {
                if isNew {
                    NewStickerReveal(entry: entry)
                        .id(entry.id)
                } else {
                    StickerArt(entry: entry, size: 170)
                        .padding(.top, 8)
                }

                VStack(spacing: 6) {
                    Text(entry.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Label(style.label, systemImage: style.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(style.colour.opacity(0.15), in: .capsule)
                            .foregroundStyle(style.colour)
                        if let place = entry.place {
                            Label(place.name, systemImage: "mappin")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Text(entry.body)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(entry.photos ?? [], id: \.asset) { photo in
                    LorePhotoView(photo: photo)
                }

                if let foundAt {
                    Text(foundAt == Progression.exploredSecretDate ? "Found in your explored tiles" : "Found \(foundAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !entry.sources.isEmpty {
                    DisclosureGroup("Sources") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(entry.sources, id: \.self) { source in
                                if let url = URL(string: source), url.scheme != nil {
                                    Link(url.host() ?? source, destination: url).font(.caption)
                                } else {
                                    Text(source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                    .font(.subheadline)
                }

                if isNew {
                    Button("Nice one") { dismiss() }
                        .buttonStyle(StickerButtonStyle())
                }
            }
            .padding(24)
        }
        .background(Color.cream)
        .presentationBackground(Color.cream)
        .presentationDetents(isNew ? [.medium, .large] : [.large])
    }
}

/// Just the discovery card gets the slap and chime. Reading it again stays quiet.
private struct NewStickerReveal: View {
    let entry: LoreEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var impact = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Secret found")
                .font(.subheadline.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.walkiesOrange)
                .opacity(impact ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: impact)

            StickerArt(entry: entry, size: 170)
                .scaleEffect(reduceMotion || landed ? 1 : 1.4)
                .rotationEffect(.degrees(reduceMotion || landed ? -4 : -14))
                .offset(y: reduceMotion || landed ? 0 : -65)
                .opacity(landed ? 1 : 0)
                .background {
                    SunburstView()
                        .opacity(impact ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: impact)
                }
                .background {
                    if !reduceMotion {
                        Circle()
                            .stroke(.white.opacity(0.85), lineWidth: 9)
                            .frame(width: 160, height: 160)
                            .blur(radius: 3)
                            .keyframeAnimator(initialValue: 0.0, trigger: impact) { [impact] ring, progress in
                                ring
                                    .scaleEffect(1 + progress * 0.5)
                                    .opacity(impact ? 1 - progress : 0)
                            } keyframes: { _ in
                                LinearKeyframe(1, duration: 0.4)
                            }
                    }
                }
        }
        .allowsHitTesting(false)
        .task {
            guard !landed else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.55)) {
                    landed = true
                }
                // The spring reaches the card a little before it settles.
                if !reduceMotion { try await Task.sleep(for: .milliseconds(130)) }
                try Task.checkCancellation()
                impact = true
                SoundFX.shared.play(.chime)
            } catch {
                // Closing a card before it lands mustn't leave a chime behind.
            }
        }
    }
}

/// The slow-spinning gold rays behind a sticker, on a new secret's discovery card and
/// in the walk replay's secret pop-up. Still when Reduce Motion is on.
struct SunburstView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle()
            .fill(AngularGradient(
                colors: (0..<16).map { $0 % 2 == 0 ? Color(red: 1, green: 0.85, blue: 0.4).opacity(0.55) : .clear },
                center: .center
            ))
            .frame(width: 300, height: 300)
            .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 40, endRadius: 150))
            .rotationEffect(.degrees(!reduceMotion && spin ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 12).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = !reduceMotion }
            .onChange(of: reduceMotion) { spin = !reduceMotion }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A photo under a secret's story: the picture, what it shows, and who took it, which
/// links to its page on Wikimedia Commons. Tap the picture to see it full screen.
private struct LorePhotoView: View {
    let photo: LoreEntry.Photo
    @State private var enlarged = false

    var body: some View {
        if let image = UIImage(named: photo.asset) {
            VStack(alignment: .leading, spacing: 6) {
                Button { enlarged = true } label: {
                    // A neat band, whatever shape the photo is; tap for all of it.
                    Color.clear
                        .frame(height: 230)
                        .frame(maxWidth: .infinity)
                        .overlay { Image(uiImage: image).resizable().scaledToFill() }
                        .clipShape(.rect(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(photo.caption.isEmpty ? "Photo" : photo.caption)

                if !photo.caption.isEmpty {
                    Text(photo.caption)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink.opacity(0.8))
                }
                if let url = URL(string: photo.source) {
                    Link(destination: url) {
                        Text("Photo: \(photo.credit.isEmpty ? "Wikimedia Commons" : photo.credit)")
                            .font(.caption)
                            .foregroundStyle(Color.ink.opacity(0.5))
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fullScreenCover(isPresented: $enlarged) {
                ZoomablePhoto(image: image) { enlarged = false }
            }
        }
    }
}

/// A photo filling the screen on black, pinch to zoom, tap to close.
private struct ZoomablePhoto: View {
    let image: UIImage
    let onClose: () -> Void
    @State private var scale = 1.0
    @GestureState private var pinch = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in scale = min(4, max(1, scale * value.magnification)) }
                )
        }
        .onTapGesture(perform: onClose)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}

