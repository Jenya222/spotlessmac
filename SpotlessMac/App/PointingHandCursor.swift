import AppKit
import SwiftUI

/// Shows the pointing-hand cursor over clickable elements so it is clear
/// what can be clicked. Disabled elements keep the arrow.
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
    /// For clickable things that are not `Button`s: tappable rows, pickers,
    /// toggles, steppers, menus.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

/// Wraps any system button style and adds the pointing-hand cursor, so every
/// `Button` gets it without per-call-site modifiers.
struct HandCursorButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(base)
            .pointingHandCursor()
    }
}

extension PrimitiveButtonStyle where Self == HandCursorButtonStyle<DefaultButtonStyle> {
    /// Applied once at the window root: buttons without an explicit style.
    static var automaticHand: Self { .init(base: .automatic) }
}

extension PrimitiveButtonStyle where Self == HandCursorButtonStyle<PlainButtonStyle> {
    static var plainHand: Self { .init(base: .plain) }
}

extension PrimitiveButtonStyle where Self == HandCursorButtonStyle<BorderedButtonStyle> {
    static var borderedHand: Self { .init(base: .bordered) }
}

extension PrimitiveButtonStyle where Self == HandCursorButtonStyle<BorderedProminentButtonStyle> {
    static var borderedProminentHand: Self { .init(base: .borderedProminent) }
}
