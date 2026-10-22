import SwiftUI

/// The B2 dock: a cream sticker pill, with the current tab lifted into an orange hex.
struct FloatingTabBar: View {
    /// The pill is 64 pt, and the raised hex comes up 32 pt above it.
    static let height: CGFloat = 96
    private static let pill: CGFloat = 64

    @Binding var selection: AppNavigation.Tab
    let rewards: Int
    let bookTilt: Double
    let bookPlusOne: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppNavigation.Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: Self.height)
        .background(alignment: .bottom) {
            Capsule()
                .fill(Color.cream)
                .overlay(Capsule().strokeBorder(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                .frame(height: Self.pill)
        }
        .environment(\.colorScheme, .light)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tabButton(_ tab: AppNavigation.Tab) -> some View {
        let selected = selection == tab
        let badge = tab == .progress && rewards > 0 ? String(rewards) : tab == .secrets && bookPlusOne ? "+1" : nil
        return Button {
            guard selection != tab else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65)) {
                selection = tab
            }
        } label: {
            ZStack(alignment: .top) {
                if selected {
                    Hexagon()
                        .fill(Color.walkiesOrange)
                        .overlay(Hexagon().strokeBorder(.white, style: StrokeStyle(lineWidth: 3.5, lineJoin: .round)))
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
                        .frame(width: 56, height: 64)
                        .offset(y: 1)
                        .transition(reduceMotion ? .identity : .scale(scale: 0.7).combined(with: .opacity))
                }
                Image(tab.art)
                    .renderingMode(selected ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .opacity(selected ? 1 : 0.85)
                    .rotationEffect(.degrees(tab == .secrets ? bookTilt : 0))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.walkiesOrange, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white, lineWidth: 1.5))
                                .fixedSize()
                                .offset(x: 11, y: -5)
                        }
                    }
                    .offset(y: selected ? 19.5 : 40.5)
                Text(tab.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.walkiesOrange : Color.ink.opacity(0.6))
                    .lineLimit(1)
                    .offset(y: 72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height, alignment: .top)
            // Taps above the pill reach the page, except on the raised hex.
            .contentShape(BottomRect(height: selected ? Self.height : Self.pill))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab == .progress && rewards > 0 ? "\(rewards) \(rewards == 1 ? "reward" : "rewards") waiting" : tab == .secrets && bookPlusOne ? "1 new secret" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The bottom `height` of the space it's given.
private struct BottomRect: Shape {
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height))
    }
}

private extension AppNavigation.Tab {
    var title: String {
        switch self {
        case .map: "Map"
        case .secrets: "Secrets"
        case .progress: "Progress"
        case .walks: "Walks"
        case .settings: "Settings"
        }
    }

    var art: String {
        switch self {
        case .map: "icon-map"
        case .secrets: "icon-book"
        case .progress: "progress-shell"
        case .walks: "icon-walk"
        case .settings: "icon-gear"
        }
    }
}
