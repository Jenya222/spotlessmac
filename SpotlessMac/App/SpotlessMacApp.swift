import SwiftUI

@main
struct SpotlessMacApp: App {
    @State private var selectedTab = AppTab.launchTab()

    var body: some Scene {
        WindowGroup {
            ContentView(selectedTab: $selectedTab)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 920, height: 604)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { selectedTab = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
