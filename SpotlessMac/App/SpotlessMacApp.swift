import AppKit
import SwiftUI

@main
struct SpotlessMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 920, height: 604)

        Settings {
            SpotlessMacSettingsView()
        }
    }
}

private struct SpotlessMacSettingsView: View {
    @State private var fdaStatus: FDAStatus = .unknown

    private let fullDiskAccessURL = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    var body: some View {
        Form {
            LabeledContent("Полный доступ к диску") {
                HStack(spacing: 8) {
                    Image(systemName: fdaStatus == .granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(fdaStatus == .granted ? Color.green : Color.orange)
                    Text(fdaStatus == .granted ? "Включён" : "Не включён")
                }
            }

            HStack {
                Button("Открыть настройки macOS") {
                    NSWorkspace.shared.open(fullDiskAccessURL)
                }
                Spacer()
                Button("Проверить снова") {
                    fdaStatus = FDAService.detect()
                }
            }

            LabeledContent("Версия") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { fdaStatus = FDAService.detect() }
    }
}
