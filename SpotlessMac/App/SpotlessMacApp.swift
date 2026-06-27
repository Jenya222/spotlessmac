import SwiftUI

@main
struct SpotlessMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 800, height: 540)
    }
}
