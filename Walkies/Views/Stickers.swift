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
    @Environment(\.dismiss) private var dismiss
    @State private var open: LoreEntry?

    var body: some View {
        // Found ones first, newest at the top, then the rest.
        let stickers = model.stickersHere.sorted { a, b in
            switch (model.foundStickers[a.entry.id], model.foundStickers[b.entry.id]) {
            case let (x?, y?): x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.entry.title < b.entry.title
            }
        }
        let found = stickers.filter { model.foundStickers[$0.entry.id] != nil }.count

        NavigationStack {
            Group {
                if stickers.isEmpty {
                    ContentUnavailableView(
                        "No stickers here yet",
                        systemImage: "book.closed",
                        description: Text("There's no lore for this place yet. Geographe and the rest of Busselton have some.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(found) of \(stickers.count) found")
                                .font(.headline)
                            ProgressBar(value: Double(found) / Double(stickers.count))
                            Text("Each one is a story about the area, hidden under the clouds. The gold sparkles on the map show where.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 20) {
                            ForEach(stickers, id: \.entry.id) { item in
                                let isFound = model.foundStickers[item.entry.id] != nil
                                Button {
                                    if isFound { open = item.entry }
                                } label: {
                                    StickerTile(entry: item.entry, found: isFound)
                                }
                                .buttonStyle(.plain)
                                .disabled(!isFound)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Sticker book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $open) { entry in
                LoreCardView(entry: entry, foundAt: model.foundStickers[entry.id])
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
                    Text("New sticker")
                        .font(.subheadline.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.walkiesOrange)
                }
                StickerArt(entry: entry, size: 170)
                    .padding(.top, isNew ? 0 : 8)

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

                if let foundAt {
                    Text("Found \(foundAt.formatted(date: .abbreviated, time: .shortened))")
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
                    Button {
                        dismiss()
                    } label: {
                        Text("Into the book").font(.headline).frame(maxWidth: .infinity)
                    }
                    .prominentButton()
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .presentationDetents(isNew ? [.medium, .large] : [.large])
    }
}
