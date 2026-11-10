import SwiftUI
import UIKit

/// On iPadOS 26 and later, an iPhone app runs in a window with its controls (the three
/// dots) drawn over its top-left corner. Navigation bars move out of the way by themselves,
/// but the map's floating chips don't, and App Review rejected 1.0.0 for the Places chip
/// sitting under them (Guideline 4, iPad Air, 10 Nov 2026). This pads a view's leading edge
/// by however far it has to move to clear them, which is nothing on an iPhone.
extension View {
    func clearOfWindowControls() -> some View {
        modifier(ClearOfWindowControls())
    }
}

private struct ClearOfWindowControls: ViewModifier {
    @State private var leading: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            // Measured behind the content, over the same area, so UIKit can tell whether
            // this part of the screen is next to the controls.
            .background(WindowControlsProbe(leading: $leading).allowsHitTesting(false))
    }
}

private struct WindowControlsProbe: UIViewRepresentable {
    @Binding var leading: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { value in
            // After this layout pass, so SwiftUI isn't changed mid-update.
            DispatchQueue.main.async { if leading != value { leading = value } }
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            measure()
        }

        private func measure() {
            guard #available(iOS 26, *) else { return }
            // The safe area adapted for the window's corner controls, less the ordinary one,
            // is the room the controls take up next to this view.
            let adapted = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
            let plain = directionalEdgeInsets(for: .safeArea())
            onChange?(max(0, adapted.leading - plain.leading))
        }
    }
}
