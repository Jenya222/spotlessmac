import SwiftUI

struct AssistantSettingsCard: View {
    let assistant: AssistantViewModel

    @State private var draft = AssistantSettings()
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    @State private var isChecking = false
    @State private var status: ConnectionCheckResult?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Провайдер") {
                Picker("Провайдер", selection: providerBinding) {
                    ForEach(AssistantProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 430)
                .pointingHandCursor()
            }
            row("Адрес сервера") {
                TextField(draft.provider.defaultBaseURL, text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .accessibilityLabel("Адрес сервера")
            }
            if draft.provider.usesAPIKey {
                row("Токен", hint: "Хранится в Keychain") {
                    SecureField(draft.provider.requiresAPIKey ? "Ключ API" : "Необязательно для localhost", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .accessibilityLabel("Токен")
                }
            }
            row("Модель") {
                HStack(spacing: 6) {
                    TextField("например, gpt-oss:20b", text: $draft.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .accessibilityLabel("Модель")
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model) { draft.model = model }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .pointingHandCursor()
                    .frame(width: 32)
                    .disabled(models.isEmpty)
                    .help("Выбрать из списка")
                    Button {
                        Task { await loadModels() }
                    } label: {
                        if isLoadingModels { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .help("Обновить список моделей")
                }
            }
            row("Инструменты", hint: "«Авто» пробует нативный вызов инструментов и переходит на текстовый план, если модель их не поддерживает") {
                Picker("Инструменты", selection: $draft.toolMode) {
                    ForEach(AssistantToolMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .pointingHandCursor()
            }
            row("Тайм-аут") {
                Stepper("\(draft.timeoutSeconds) с", value: $draft.timeoutSeconds, in: AssistantSettings.timeoutRange, step: 10)
                    .pointingHandCursor()
            }

            Divider()

            HStack(spacing: 10) {
                Button("Проверить подключение") { Task { await check() } }
                    .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
                if let status {
                    Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(status.ok ? Theme.healthGreenText : Theme.warningOrange)
                        .lineLimit(3)
                }
                Spacer()
                Button("Сбросить") { reset() }
                Button("Сохранить") {
                    assistant.saveSettings(draft, apiKey: apiKey)
                    status = ConnectionCheckResult(ok: true, message: "Сохранено", toolsSupported: nil)
                }
                .buttonStyle(.borderedProminentHand)
            }
            .buttonStyle(.borderedHand)

            Text("Для облачных провайдеров пути обезличиваются: имя пользователя заменяется на ~, названия папок и файлов в личных папках и папках проектов — на <папка-N>. Содержимое файлов не отправляется.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            reset()
        }
        // The saved token follows only the saved provider and host: editing the address to another
        // host clears it, and returning to the saved host brings the saved token back.
        .onChange(of: tokenBelongsToDraft) { _, belongs in
            apiKey = belongs ? assistant.currentAPIKey() : ""
        }
    }

    private var tokenBelongsToDraft: Bool {
        draft.sharesTokenEndpoint(with: assistant.settings)
    }

    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { draft.provider },
            set: { provider in
                draft.switchProvider(to: provider)
                // A key typed for one provider or host must never reach another endpoint by accident.
                apiKey = tokenBelongsToDraft ? assistant.currentAPIKey() : ""
                models = []
                status = nil
            }
        )
    }

    private func reset() {
        draft = assistant.settings
        apiKey = assistant.currentAPIKey()
        status = nil
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await assistant.fetchModels(for: draft, apiKey: apiKey)
            if draft.trimmedModel.isEmpty, let first = models.first { draft.model = first }
            status = ConnectionCheckResult(ok: true, message: "Найдено моделей: \(models.count)", toolsSupported: nil)
        } catch {
            status = .failure(error)
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        status = await assistant.checkConnection(for: draft, apiKey: apiKey)
    }

    private func row<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            content()
        }
    }
}
