import AppKit
import SwiftUI

/// Shows the pointing-hand cursor over clickable elements that have no
/// visible button chrome (plain-style icon buttons, tappable rows, borderless
/// menus), so it is clear what can be clicked. Disabled elements keep the arrow.
private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.onContinuousHover { phase in
                switch phase {
                case .active where isEnabled: NSCursor.pointingHand.set()
                case .active, .ended: NSCursor.arrow.set()
                }
            }
        }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}
