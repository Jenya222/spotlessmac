import SwiftUI

struct AssistantSettingsCard: View {
    // The card owns a one-time editing session seeded from the saved settings.
    @State private var editor: AssistantSettingsEditor
    @State private var loaded = false

    init(assistant: AssistantViewModel) {
        _editor = State(initialValue: AssistantSettingsEditor(
            loadSettings: { assistant.settings },
            loadAPIKey: { assistant.currentAPIKey() },
            fetchModels: { try await assistant.fetchModels(for: $0, apiKey: $1) },
            checkConnection: { await assistant.checkConnection(for: $0, apiKey: $1) },
            saveSettings: { assistant.saveSettings($0, apiKey: $1) }
        ))
    }

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
                TextField(editor.draft.provider.defaultBaseURL, text: $editor.settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .accessibilityLabel("Адрес сервера")
            }
            if editor.draft.provider.usesAPIKey {
                row("Токен", hint: "Хранится в Keychain") {
                    SecureField(editor.draft.provider.requiresAPIKey ? "Ключ API" : "Необязательно для localhost", text: $editor.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .accessibilityLabel("Токен")
                }
            }
            row("Модель") {
                HStack(spacing: 6) {
                    TextField("например, gpt-oss:20b", text: $editor.settings.model)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 210)
                        .accessibilityLabel("Модель")
                    Menu {
                        ForEach(editor.models, id: \.self) { model in
                            Button(model) { editor.settings.model = model }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .pointingHandCursor()
                    .frame(width: 32)
                    .disabled(editor.models.isEmpty)
                    .help("Выбрать из списка")
                    Button {
                        Task { await editor.loadModels() }
                    } label: {
                        if editor.isLoadingModels { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .help("Обновить список моделей")
                }
            }
            row("Инструменты", hint: "«Авто» пробует нативный вызов инструментов и переходит на текстовый план, если модель их не поддерживает") {
                Picker("Инструменты", selection: $editor.settings.toolMode) {
                    ForEach(AssistantToolMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .pointingHandCursor()
            }
            row("Тайм-аут") {
                Stepper("\(editor.draft.timeoutSeconds) с", value: $editor.settings.timeoutSeconds, in: AssistantSettings.timeoutRange, step: 10)
                    .pointingHandCursor()
            }

            Divider()

            HStack(spacing: 10) {
                Button("Проверить подключение") { Task { await editor.check() } }
                    .disabled(editor.isChecking)
                if editor.isChecking { ProgressView().controlSize(.small) }
                if let status = editor.status {
                    Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(status.ok ? Theme.healthGreenText : Theme.warningOrange)
                        .lineLimit(3)
                }
                Spacer()
                Button("Сбросить") { editor.reset() }
                Button("Сохранить") { editor.save() }
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
            editor.reset()
        }
    }

    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { editor.draft.provider },
            set: { provider in
                var updated = editor.draft
                updated.switchProvider(to: provider)
                editor.updateSettings(updated)
            }
        )
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
