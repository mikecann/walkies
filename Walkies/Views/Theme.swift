import SwiftUI
import UIKit

extension UIColor {
    static let walkiesOrange = UIColor(red: 1.0, green: 0.47, blue: 0.18, alpha: 1)
    static let walkiesTeal = UIColor(red: 0.13, green: 0.65, blue: 0.6, alpha: 1)
}

extension Color {
    static let walkiesOrange = Color(uiColor: .walkiesOrange)
    static let walkiesTeal = Color(uiColor: .walkiesTeal)

    // The look picked from the concept art: cream die-cut cards like the secret
    // stickers, on top of the satellite map and clouds.
    /// Card paper.
    static let cream = Color(red: 0.984, green: 0.957, blue: 0.902)
    /// The darker cream of hex badges and progress tracks.
    static let sand = Color(red: 0.918, green: 0.859, blue: 0.753)
    /// Text on cream: a warm near-black rather than pure black.
    static let ink = Color(red: 0.231, green: 0.192, blue: 0.169)
    /// Main buttons: Start walk, End walk.
    static let burnt = Color(red: 0.79, green: 0.34, blue: 0.23)
    static let badgeGreen = Color(red: 0.62, green: 0.77, blue: 0.58)
    static let badgeTeal = Color(red: 0.29, green: 0.58, blue: 0.58)
}

extension View {
    /// A cream card with a white die-cut edge and a soft shadow, like a sticker.
    func stickerCard<S: InsettableShape>(in shape: S) -> some View {
        background(Color.cream, in: shape)
            .overlay(shape.strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .foregroundStyle(Color.ink)
            .environment(\.colorScheme, .light)
    }
}

/// A pointy-topped hexagon, matching the map's tiles.
struct Hexagon: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width / 3.0.squareRoot(), rect.height / 2) - inset
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<6 {
            let a = (60 * Double(i) - 90) * .pi / 180
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Hexagon {
        Hexagon(inset: inset + amount)
    }
}

/// A round map control as a hexagon badge, with one of the illustrated icons or a symbol.
struct HexBadge: View {
    enum Icon {
        case art(String)
        case symbol(String)
    }

    let icon: Icon
    var fill: Color = .sand
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Hexagon().fill(fill)
                Hexagon().strokeBorder(.white, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                switch icon {
                case .art(let name):
                    Image(name).resizable().scaledToFit().frame(width: 34, height: 34)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 54, height: 60)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .contentShape(Hexagon())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// The big Start walk and End walk buttons: burnt orange with a white die-cut edge.
struct StickerButtonStyle: ButtonStyle {
    var fill: Color = .burnt
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill, in: .capsule)
            .overlay(Capsule().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

enum Format {
    static func distance(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres)) m" : String(format: "%.2f km", metres / 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func area(_ squareMetres: Double) -> String {
        let km2 = squareMetres / 1_000_000
        return km2 < 10 ? String(format: "%.1f km²", km2) : "\(Int(km2.rounded())) km²"
    }
}

extension View {
    /// Liquid glass on iOS 26, frosted material on older phones.
    @ViewBuilder
    func glassCard<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func prominentButton() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.sand)
                Capsule()
                    .fill(Color.walkiesOrange)
                    .frame(width: max(6, geo.size.width * min(1, value)))
            }
        }
        .frame(height: 6)
        .animation(.spring, value: value)
    }
}
