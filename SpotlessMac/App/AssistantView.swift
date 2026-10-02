import SwiftUI

struct AssistantView: View {
    @Bindable var viewModel: AssistantViewModel
    var onOpenSettings: () -> Void
    var onScan: () -> Void

    private let suggestions = [
        "Почему диск заполнен?",
        "Освободи 20 ГБ безопасно",
        "Что можно удалить из Docker?",
        "Хватит ли места на обновление macOS?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.isConfigured {
                conversation
                Divider()
                composer
            } else {
                notConfigured
            }
        }
        .background(Theme.dashboardBackground.opacity(0.38))
        .onAppear { viewModel.reloadSettings() }
        .task { await viewModel.refreshContext() }
        // The view model keeps the pending send/retry while the sheet is up. Accept and
        // switch-to-local consume it first; any other dismissal (Esc, click outside, Cancel)
        // lands here, and cancelCloudDisclosure() is a harmless no-op after the others.
        .sheet(isPresented: $viewModel.isCloudDisclosurePresented, onDismiss: { viewModel.cancelCloudDisclosure() }) {
            CloudDisclosureSheet(
                onAccept: viewModel.acceptCloudDisclosure,
                onUseLocal: viewModel.switchToLocalAfterDisclosure,
                onCancel: viewModel.cancelCloudDisclosure
            )
        }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Ассистент")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Новый диалог", systemImage: "square.and.pencil") { viewModel.newConversation() }
                .buttonStyle(.bordered)
                .disabled(viewModel.messages.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var subtitle: String {
        let model = viewModel.settings.trimmedModel.isEmpty ? "модель не выбрана" : viewModel.settings.trimmedModel
        return "\(viewModel.settings.provider.title) · \(model)"
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if viewModel.messages.isEmpty { improvementsPanel }
                    ForEach(viewModel.messages) { message in
                        AssistantMessageView(
                            message: message,
                            canRetry: message.id == viewModel.messages.last?.id && !viewModel.isStreaming,
                            onOpenPlan: { viewModel.openPlan(messageID: message.id) },
                            onDismissPlan: { viewModel.dismissPlan(messageID: message.id) },
                            onRetry: viewModel.retry,
                            onOpenSettings: onOpenSettings
                        )
                        .equatable()
                        .id(message.id)
                    }
                    if let status = viewModel.statusLine {
                        Label(status, systemImage: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: viewModel.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var improvementsPanel: some View {
        let improvements = ImprovementAdvisor.suggestions(for: viewModel.currentSnapshot())
        VStack(alignment: .leading, spacing: 10) {
            Text("ЧТО МОЖНО УЛУЧШИТЬ")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accentGradientStart)
            if improvements.isEmpty {
                Text("Явных проблем не найдено. Спросите ассистента о чём угодно.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(improvements) { improvement in
                Button { handle(improvement) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: improvement.icon)
                            .frame(width: 22)
                            .foregroundStyle(Theme.accentGradientStart)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(improvement.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(improvement.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(improvement.action == .scan ? "Запустить сканирование" : "Спросить")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accentGradientStart)
                    }
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.divider))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isStreaming)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = viewModel.planNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warningOrange)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { viewModel.send(suggestion) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(viewModel.isStreaming)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Спросите про файлы, кеши или место на диске…", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit { viewModel.send() }
                if viewModel.isStreaming {
                    Button("Стоп", systemImage: "stop.fill") { viewModel.stop() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Отправить", systemImage: "arrow.up.circle.fill") { viewModel.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Ассистент только советует. Удаляете вы сами — в Корзину, после проверки списка.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var notConfigured: some View {
        ContentUnavailableView {
            Label("Подключите модель", systemImage: "sparkles")
        } description: {
            Text("Укажите Ollama Cloud, локальную Ollama или OpenAI-совместимый сервер, чтобы получать советы по очистке.")
        } actions: {
            Button("Открыть настройки", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ improvement: Improvement) {
        switch improvement.action {
        case .ask(let question): viewModel.send(question)
        case .scan: onScan()
        }
    }
}
