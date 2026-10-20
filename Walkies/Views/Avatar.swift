import CryptoKit
import SwiftUI
import UIKit

/// Someone's head for the map picker: their photo, or their initials on their colour.
struct Head: Identifiable, Equatable {
    var id: String
    var name: String?
    var picture: URL?
    var colour: Color

    /// "MC" for Mike Cann, "M" for Mike, "?" with nothing to go on. An email works too.
    nonisolated static func initials(_ name: String?) -> String {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return "?" }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" })
            .compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        guard let first = words.first else { return "?" }
        let letters = words.count > 1 ? [first, words.last!] : [first]
        return letters.map { String($0).uppercased() }.joined()
    }

    /// Your own head. Your colour from a team map if you've picked one, else Walkies orange.
    static func you(_ account: Account, teams: [TeamMap]) -> Head {
        let colour = teams.lazy.compactMap(\.you).first.map { Color.team($0.colour) } ?? .walkiesOrange
        return Head(id: "you", name: account.displayName, picture: account.picture, colour: colour)
    }

    /// A team's heads, you last so you sit on top of the pile.
    static func team(_ team: TeamMap, you: Head) -> [Head] {
        let others = team.members.filter { !$0.isYou }.map {
            Head(id: $0.userId, name: $0.name, picture: $0.picture.flatMap(URL.init(string:)), colour: .team($0.colour))
        }
        guard let member = team.you else { return others }
        // Your own photo wins: it's there before the team syncs, and the debug override shows.
        let mine = Head(id: member.userId, name: member.name, picture: you.picture ?? member.picture.flatMap(URL.init(string:)), colour: .team(member.colour))
        return others + [mine]
    }
}

/// Which heads fit in a pile and how many go in the "+N" bubble. Keeps your own
/// head (the last one) when it has to leave some out.
nonisolated enum HeadPile {
    static func visible<T>(_ heads: [T], max: Int = 3) -> (shown: [T], extra: Int) {
        guard heads.count > max, max > 0 else { return (heads, 0) }
        return (Array(heads.prefix(max - 1)) + [heads.last!], heads.count - max)
    }
}

/// A round head with a white sticker edge.
struct Avatar: View {
    let head: Head
    var size: CGFloat = 44
    var border: CGFloat = 2.5
    @State private var image: UIImage?

    init(_ head: Head, size: CGFloat = 44, border: CGFloat = 2.5) {
        self.head = head
        self.size = size
        self.border = border
        // Straight from the cache, so a head that's loaded before doesn't flicker in.
        _image = State(initialValue: head.picture.flatMap { HeadImages.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(head.colour.gradient)
                Text(Head.initials(head.name))
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(.white, lineWidth: border))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .accessibilityHidden(true)
        .task(id: head.picture) {
            guard let url = head.picture else { image = nil; return }
            image = HeadImages.shared.cached(url)
            if image == nil { image = await HeadImages.shared.load(url) }
        }
    }
}

/// Heads overlapping like a little pile of stickers, with "+N" for the rest.
struct AvatarStack: View {
    let heads: [Head]
    var size: CGFloat = 30
    var border: CGFloat = 2.5
    var overlap: CGFloat = 10
    var max = 3

    var body: some View {
        let pile = HeadPile.visible(heads, max: max)
        HStack(spacing: -overlap) {
            ForEach(pile.shown) { Avatar($0, size: size, border: border) }
            if pile.extra > 0 {
                Text("+\(pile.extra)")
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .background(Color.sand, in: .circle)
                    .overlay(Circle().strokeBorder(.white, lineWidth: border))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Downloaded head photos, kept in memory and in Caches so heads show straight
/// away and offline after the first load.
final class HeadImages {
    static let shared = HeadImages()

    private let memory = NSCache<NSURL, UIImage>()
    private var loading: [URL: Task<UIImage?, Never>] = [:]
    private let folder = URL.cachesDirectory.appending(path: "Heads", directoryHint: .isDirectory)

    func cached(_ url: URL) -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        guard let data = try? Data(contentsOf: file(for: url)), let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    /// One download per photo, however many heads ask for it at once.
    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let file = file(for: url), folder = folder
        let task = Task { () -> UIImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: Self.sized(url)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return image
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    private func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: hash)
    }

    /// Google hands out 96px photos, which look soft on a 44pt head. Ask for a bigger one.
    private nonisolated static func sized(_ url: URL) -> URL {
        guard url.host()?.hasSuffix("googleusercontent.com") == true,
              let range = url.absoluteString.range(of: #"=s\d+-c$"#, options: .regularExpression)
        else { return url }
        return URL(string: url.absoluteString.replacingCharacters(in: range, with: "=s192-c")) ?? url
    }
}
