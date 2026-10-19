import SwiftUI
import UIKit

extension UIColor {
    static let walkiesOrange = UIColor(red: 1.0, green: 0.47, blue: 0.18, alpha: 1)
    static let walkiesTeal = UIColor(red: 0.13, green: 0.65, blue: 0.6, alpha: 1)
}

extension Color {
    static let walkiesOrange = Color(uiColor: .walkiesOrange)
    static let walkiesTeal = Color(uiColor: .walkiesTeal)
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
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.walkiesTeal, .walkiesOrange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(1, value)))
            }
        }
        .frame(height: 6)
        .animation(.spring, value: value)
    }
}
