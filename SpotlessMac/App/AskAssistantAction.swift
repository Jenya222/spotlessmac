import SwiftUI

struct AskAssistantAction {
    let handler: @MainActor (AssistantFocus) -> Void

    @MainActor
    func callAsFunction(_ focus: AssistantFocus) {
        handler(focus)
    }
}

private struct AskAssistantKey: EnvironmentKey {
    static var defaultValue: AskAssistantAction? { nil }
}

extension EnvironmentValues {
    var askAssistant: AskAssistantAction? {
        get { self[AskAssistantKey.self] }
        set { self[AskAssistantKey.self] = newValue }
    }
}

// Shared ⓘ button + context menu entry for result rows.
struct AskAssistantButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .foregroundStyle(Theme.textSecondary)
        .help("Спросить ассистента")
        .accessibilityLabel("Спросить ассистента")
    }
}

extension View {
    func askAssistantMenu(_ onAsk: (() -> Void)?) -> some View {
        contextMenu {
            if let onAsk { Button("Спросить ассистента", systemImage: "sparkles", action: onAsk) }
        }
    }
}
