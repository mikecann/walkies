import SwiftUI

nonisolated enum CosmeticArt {
    static func marker(_ id: String) -> String? {
        switch id {
        case "marker.sneaker": "progress-marker-sneaker"
        case "marker.boat": "progress-marker-boat"
        case "marker.hat": "progress-marker-hat"
        case "marker.lighthouse": "progress-marker-lighthouse"
        default: nil
        }
    }

    static func cover(_ id: String) -> String? {
        switch id {
        case "cover.seashell": "progress-cover-seashell"
        case "cover.map": "progress-cover-map"
        case "cover.gold": "progress-cover-gold"
        default: nil
        }
    }
}

/// Retains the original card for the free cover. A cream wash over paid cover art
/// gives the summary consistent contrast, including with larger accessibility text.
struct SecretsCover: ViewModifier {
    var equipped: String

    func body(content: Content) -> some View {
        if let asset = CosmeticArt.cover(equipped) {
            content
                .background {
                    GeometryReader { geometry in
                        Image(asset)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .overlay(Color.cream.opacity(0.68))
                            .clipped()
                    }
                }
                .clipShape(.rect(cornerRadius: 24))
                .stickerCard(in: RoundedRectangle(cornerRadius: 24))
        } else {
            content.stickerCard(in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
