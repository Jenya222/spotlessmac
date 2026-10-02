import AppKit
import SwiftUI

struct SpotlessMacSettingsView: View {
    var viewModel: ScanViewModel
    var licenseManager: LicenseManager
    var assistant: AssistantViewModel? = nil
    @Binding var showActivation: Bool
    @Binding var showOnboarding: Bool

    @AppStorage("launchTab") private var launchTab = AppTab.care.rawValue

    private let fullDiskAccessURL = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                generalCard
                assistantCard
                accessCard
                licenseCard
                aboutCard
            }
            .frame(maxWidth: 760)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.dashboardBackground.opacity(0.38))
        .onAppear { viewModel.checkFDA() }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Настройки")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Параметры SpotlessMac и доступ к системе")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var generalCard: some View {
        settingsCard("ОБЩИЕ", icon: "slider.horizontal.3", iconColor: Theme.accentGradientStart) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Стартовый раздел")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Откроется при следующем запуске приложения")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Picker("Стартовый раздел", selection: $launchTab) {
                    ForEach(AppTab.mainTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("Стартовый раздел")
            }
        }
    }

    @ViewBuilder
    private var assistantCard: some View {
        if let assistant {
            settingsCard("АССИСТЕНТ", icon: "sparkles", iconColor: Theme.accentGradientStart) {
                AssistantSettingsCard(assistant: assistant)
            }
        }
    }

    private var accessCard: some View {
        settingsCard("ДОСТУП К ДИСКУ", icon: "checkmark.shield.fill", iconColor: Theme.healthGreenText) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Полный доступ к диску")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Нужен для поиска системных логов и некоторых кешей")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Label(
                    viewModel.fdaStatus == .granted ? "Включён" : "Не включён",
                    systemImage: viewModel.fdaStatus == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.fdaStatus == .granted ? Theme.healthGreenText : Theme.warningOrange)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Открыть настройки macOS") {
                    NSWorkspace.shared.open(fullDiskAccessURL)
                }
                Button("Проверить снова") { viewModel.checkFDA() }
                Spacer()
                Button("Как включить доступ") { showOnboarding = true }
            }
            .buttonStyle(.bordered)
        }
    }

    private var licenseCard: some View {
        settingsCard("ЛИЦЕНЗИЯ", icon: "key.fill", iconColor: Theme.warningOrange) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SpotlessMac")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(licenseDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
#if !DEBUG
                if !licenseManager.isActivated {
                    Button("Активировать") { showActivation = true }
                        .buttonStyle(.borderedProminent)
                }
#endif
            }
        }
    }

    private var aboutCard: some View {
        settingsCard("О ПРИЛОЖЕНИИ", icon: "info.circle.fill", iconColor: Theme.accentGradientStart) {
            HStack {
                Text("Версия SpotlessMac")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(versionDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var licenseDescription: String {
#if DEBUG
        return "Режим разработчика · очистка без активации"
#else
        switch licenseManager.state {
        case .activated(let email): return "Активировано для \(email)"
        case .trial(let used, let allowed): return "Пробный режим · использовано \(used) из \(allowed) очисток"
        }
#endif
    }

    private var versionDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func settingsCard<Content: View>(
        _ title: String,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(iconColor)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }
}
