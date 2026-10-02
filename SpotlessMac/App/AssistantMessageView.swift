import SwiftUI

// Equatable on message + canRetry only: the closures just capture the message id, so an
// unchanged completed message is not re-evaluated for every token streamed into the last one.
struct AssistantMessageView: View, Equatable {
    let message: AssistantMessage
    var canRetry: Bool
    var onOpenPlan: () -> Void
    var onDismissPlan: () -> Void
    var onRetry: () -> Void
    var onOpenSettings: () -> Void

    nonisolated static func == (lhs: AssistantMessageView, rhs: AssistantMessageView) -> Bool {
        lhs.message == rhs.message && lhs.canRetry == rhs.canRetry
    }

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        }
    }

    private var assistantBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.text.isEmpty && message.status == .streaming {
                ProgressView().controlSize(.small)
            } else if !message.text.isEmpty {
                if message.status == .streaming {
                    // Parsing markdown on every streamed token is wasted work: show the raw
                    // text while it arrives and format it once the message is complete.
                    Text(message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AssistantMarkdownView(markdown: message.text)
                }
            }
            if let plan = message.plan, !message.planDismissed {
                AssistantPlanCard(plan: plan, onOpen: onOpenPlan, onDismiss: onDismissPlan)
            }
            if message.planMalformed {
                Text("Ассистент попытался предложить план, но его не удалось разобрать.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warningOrange)
            }
            if let error = message.errorText {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warningOrange)
                    Spacer()
                    if message.errorOpensSettings {
                        Button("Настройки", action: onOpenSettings).controlSize(.small)
                    }
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if canRetry && [.failed, .interrupted, .stopped].contains(message.status) {
                    Button("Повторить", action: onRetry).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.divider))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private var caption: String {
        let note: String? = switch message.status {
        case .stopped: "остановлено"
        case .interrupted: "ответ прерван"
        default: nil
        }
        return [message.model, message.createdAt.formatted(date: .omitted, time: .shortened), note]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct AssistantPlanCard: View {
    let plan: AssistantPlan
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("План: \(plan.itemIDs.count) элементов · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))",
                  systemImage: "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if !plan.reason.isEmpty {
                Text(plan.reason).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if !plan.skipped.isEmpty {
                Text("Пропущено: " + plan.skipped.map { "\($0.count) — \($0.label)" }.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !plan.manualReview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Проверьте и удалите вручную:").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(plan.manualReview.enumerated()), id: \.offset) { _, line in
                        Text("• " + line).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text("Ассистент ничего не удаляет: вы увидите список и сами решите, что отправить в Корзину.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                Button("Открыть в превью", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.isEmpty)
                Button("Отклонить", action: onDismiss)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningBackground)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.warningBorder))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow))
    }
}

struct CloudDisclosureSheet: View {
    var onAccept: () -> Void
    var onUseLocal: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Данные уйдут в облако", systemImage: "icloud.and.arrow.up")
                .font(.system(size: 17, weight: .bold))
            Text("Чтобы ответить, ассистент отправит выбранному провайдеру:")
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("• категории, размеры и даты найденных файлов")
                Text("• пути, где имя пользователя заменено на ~, а названия папок и файлов в личных папках и папках проектов — на <папка-N>")
                Text("• сведения о диске, Docker и остатках программ")
                Text("• состояние памяти и названия программ, которые занимают больше всего памяти")
                Text("• статус полного доступа к диску и итог последней очистки")
                Text("• текст ваших вопросов")
            }
            .font(.system(size: 12))
            Text("Содержимое файлов не отправляется никогда. Локальная Ollama работает без отправки данных с этого Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Button("Отмена", action: onCancel)
                Spacer()
                Button("Использовать локальную Ollama", action: onUseLocal)
                Button("Понятно", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
