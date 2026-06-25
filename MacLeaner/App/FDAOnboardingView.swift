import SwiftUI

struct FDAOnboardingView: View {
    let onDismiss: () -> Void

    @State private var status: FDAStatus = .unknown

    private let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Полный доступ к диску")
                    .font(.title2.bold())
                Text(
                    "MacLeaner может сканировать системные логи и кеши вне вашей домашней папки. " +
                    "Для этого требуется разрешение «Полный доступ к диску» в Системных настройках.\n\n" +
                    "Без этого разрешения сканирование пользовательских кешей продолжит работать."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            }

            statusBadge

            HStack(spacing: 12) {
                Button("Открыть Системные настройки") {
                    NSWorkspace.shared.open(settingsURL)
                }
                .buttonStyle(.borderedProminent)

                Button("Проверить ещё раз") {
                    status = FDAService.detect()
                }
            }

            Button("Продолжить без полного доступа") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 460)
        .onAppear { status = FDAService.detect() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .unknown:
            Label("Проверяется…", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .granted:
            Label("Доступ предоставлен", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label("Доступ не предоставлен", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
