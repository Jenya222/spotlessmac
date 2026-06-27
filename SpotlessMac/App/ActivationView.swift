import SwiftUI

struct ActivationView: View {
    var licenseManager: LicenseManager
    var onDismiss: () -> Void

    @State private var keyInput = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Активировать SpotlessMac")
                .font(.title2.bold())

            Text(trialMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Ключ лицензии", text: $keyInput)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(width: 440)

            if let err = licenseManager.activationError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Купить лицензию") {
                    // TODO: replace with your Lemon Squeezy / Gumroad product URL
                    if let url = URL(string: "https://TODO_YOUR_STORE_URL") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button("Отмена") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Активировать") {
                    licenseManager.activate(key: keyInput)
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: 440)
        }
        .padding(32)
        .frame(minWidth: 520)
        .onChange(of: licenseManager.isActivated) { _, activated in
            if activated { onDismiss() }
        }
    }

    private var trialMessage: String {
        switch licenseManager.state {
        case .trial(let used, let allowed):
            if used >= allowed {
                return "Вы использовали \(used) из \(allowed) бесплатных очисток. Введите ключ лицензии, чтобы продолжить."
            } else {
                return "Доступно \(allowed - used) из \(allowed) бесплатных очисток."
            }
        case .activated:
            return "Приложение активировано."
        }
    }
}
