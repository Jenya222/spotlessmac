import Foundation
import Observation

@Observable
@MainActor
final class AssistantViewModel {
    struct Dependencies {
        var settingsStore: AssistantSettingsStore
        var keyStore: any APIKeyStoring
        var makeClient: @MainActor (AssistantSettings, String) throws -> any LLMClient
        var snapshot: @MainActor () -> SystemSnapshot
        // The only outward effect of the assistant: mark items for the user's review.
        // Returns false when nothing could be staged (the plan is stale).
        var stagePlan: @MainActor (AssistantPlan) -> Bool
        var conversationStore: ConversationStore?
        var homePath: String
        // Registered project roots (absolute paths): redacted like personal folders for cloud providers.
        var personalRoots: [String] = []
        // Refreshes read-only context (memory sample) before each answer.
        var refreshContext: @MainActor () async -> Void = {}
        var now: @MainActor () -> Date = { Date() }
    }

    static let maxToolRounds = 4
    static let historyLimit = 20

    private(set) var messages: [AssistantMessage]
    private(set) var settings: AssistantSettings
    private(set) var hasAPIKey: Bool
    private(set) var isStreaming = false
    private(set) var statusLine: String?
    private(set) var planNotice: String?
    var draft = ""
    var isCloudDisclosurePresented = false

    private let deps: Dependencies
    private var redactor: PathRedactor
    private var pendingText: String?
    private var pendingFromDraft = false
    private var pendingRetry = false
    private var streamTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        deps = dependencies
        settings = dependencies.settingsStore.load()
        hasAPIKey = !dependencies.keyStore.readKey().isEmpty
        messages = dependencies.conversationStore?.load() ?? []
        redactor = PathRedactor(homePath: dependencies.homePath, extraRoots: dependencies.personalRoots)
    }

    var isConfigured: Bool {
        !settings.trimmedModel.isEmpty && (!settings.provider.requiresAPIKey || hasAPIKey)
    }

    func currentSnapshot() -> SystemSnapshot { deps.snapshot() }

    func refreshContext() async { await deps.refreshContext() }

    func reloadSettings() {
        settings = deps.settingsStore.load()
        hasAPIKey = !deps.keyStore.readKey().isEmpty
    }

    // MARK: Conversation

    func send(_ text: String? = nil) {
        let fromDraft = text == nil
        let trimmed = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        planNotice = nil
        if needsCloudDisclosure {
            pendingText = trimmed
            pendingFromDraft = fromDraft
            pendingRetry = false
            isCloudDisclosurePresented = true
            return
        }
        if fromDraft { draft = "" }
        messages.append(.user(trimmed, at: deps.now()))
        startResponse()
    }

    func ask(about focus: AssistantFocus) {
        // Row shortcuts can fire before the model is set up; the caller switches to the tab,
        // which shows the setup screen. Never queue a hidden exchange or a disclosure here.
        guard isConfigured else { return }
        let facts = focus.facts.map { "- \($0)" }.joined(separator: "\n")
        let question = "Что это и можно ли это удалить?\n\n\(focus.title)\nПуть: \(focus.path)\n\(facts)"
        if isStreaming {
            // The answer in progress is not interrupted: keep the question so the user can send it afterwards.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = question }
            return
        }
        send(question)
    }

    func acceptCloudDisclosure() {
        deps.settingsStore.cloudDisclosureAccepted = true
        isCloudDisclosurePresented = false
        resumePending()
    }

    func switchToLocalAfterDisclosure() {
        var updated = settings
        updated.switchProvider(to: .ollamaLocal)
        deps.settingsStore.save(updated)
        reloadSettings()
        isCloudDisclosurePresented = false
        resumePending()
    }

    func cancelCloudDisclosure() {
        isCloudDisclosurePresented = false
        pendingText = nil
        pendingRetry = false
    }

    func stop() {
        streamTask?.cancel()
    }

    func retry() {
        guard canRetry else { return }
        // Settings may have been switched to a cloud provider since the failure, so the first
        // send off this Mac is gated here too. The failed message stays until the user decides.
        if needsCloudDisclosure {
            pendingRetry = true
            pendingText = nil
            isCloudDisclosurePresented = true
            return
        }
        messages.removeLast()
        startResponse()
    }

    func newConversation() {
        streamTask?.cancel()
        messages = []
        planNotice = nil
        redactor = PathRedactor(homePath: deps.homePath, extraRoots: deps.personalRoots)
        persist()
    }

    func openPlan(messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }), !message.planDismissed,
              let plan = message.plan, !plan.isEmpty else { return }
        if !deps.stagePlan(plan) {
            planNotice = "Список найденного изменился — попросите ассистента составить план заново."
        }
    }

    func dismissPlan(messageID: UUID) {
        update(messageID) { $0.planDismissed = true }
        persist()
    }

    func waitUntilIdle() async {
        while let task = streamTask { await task.value }
    }

    // MARK: Settings helpers for the settings card

    func currentAPIKey() -> String { deps.keyStore.readKey() }

    func saveSettings(_ newSettings: AssistantSettings, apiKey: String) {
        deps.settingsStore.save(newSettings)
        if newSettings.provider.usesAPIKey { deps.keyStore.writeKey(apiKey) }
        reloadSettings()
    }

    func fetchModels(for candidate: AssistantSettings, apiKey: String) async throws -> [String] {
        try await deps.makeClient(candidate, apiKey).listModels()
    }

    func checkConnection(for candidate: AssistantSettings, apiKey: String) async -> ConnectionCheckResult {
        do {
            let client = try deps.makeClient(candidate, apiKey)
            let result = await AssistantConnectionTester.check(client: client, model: candidate.trimmedModel)
            if let supported = result.toolsSupported {
                deps.settingsStore.setToolSupport(supported, for: candidate.toolSupportKey)
            }
            return result
        } catch {
            return .failure(error)
        }
    }

    // MARK: Response loop

    private var needsCloudDisclosure: Bool {
        settings.sendsDataOffDevice && !deps.settingsStore.cloudDisclosureAccepted
    }

    private var canRetry: Bool {
        guard !isStreaming, let last = messages.last, last.role == .assistant else { return false }
        return [.failed, .interrupted, .stopped].contains(last.status)
    }

    private func resumePending() {
        if pendingRetry {
            // The user message is already in the history: only the failed answer is replaced.
            pendingRetry = false
            guard canRetry else { return }
            messages.removeLast()
            startResponse()
            return
        }
        guard let text = pendingText else { return }
        pendingText = nil
        if pendingFromDraft { draft = "" }
        messages.append(.user(text, at: deps.now()))
        startResponse()
    }

    private func startResponse() {
        let current = settings
        let message = AssistantMessage(id: UUID(), role: .assistant, text: "", status: .streaming,
                                       model: current.trimmedModel, createdAt: deps.now())
        messages.append(message)
        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.respond(into: message.id, settings: current)
        }
    }

    private func respond(into messageID: UUID, settings: AssistantSettings) async {
        defer {
            isStreaming = false
            statusLine = nil
            streamTask = nil
            persist()
        }
        let redacts = settings.sendsDataOffDevice
        await deps.refreshContext()
        let snapshot = Self.prepared(deps.snapshot(), redacts: redacts)
        do {
            let client = try deps.makeClient(settings, deps.keyStore.readKey())
            // Stop / new conversation during the context refresh must not render the snapshot
            // (which registers aliases) or open a request.
            try Task.checkCancellation()
            var toolsEnabled = toolsEnabled(for: settings)
            // The snapshot does not change within one answer, so it is rendered once. Rendering it
            // first registers folder aliases, so history that names the same folder gets the same alias.
            let context = SnapshotRenderer.render(snapshot) { self.format($0, redacts: redacts) }
            var conversation = wireHistory(excluding: messageID, redacts: redacts)
            var transcript = ""
            var rounds = 0
            var proposal: PlanProposal?

            while true {
                let offerTools = toolsEnabled && rounds < Self.maxToolRounds
                let request = ChatRequest(
                    model: settings.trimmedModel,
                    messages: systemMessages(toolsEnabled: toolsEnabled, context: context) + conversation,
                    tools: offerTools ? AssistantTool.specs : []
                )
                var roundText = ""
                var calls: [ToolCall] = []
                do {
                    for try await event in client.stream(request) {
                        switch event {
                        case .text(let delta):
                            roundText += delta
                            let visible = PlanParser.visibleWhileStreaming(display(transcript + roundText, redacts: redacts))
                            update(messageID) { $0.text = visible }
                        case .toolCalls(let newCalls):
                            calls += newCalls
                        case .done:
                            break
                        }
                    }
                    try Task.checkCancellation()
                } catch LLMError.toolsUnsupported where offerTools && settings.toolMode == .auto && rounds == 0 {
                    deps.settingsStore.setToolSupport(false, for: settings.toolSupportKey)
                    toolsEnabled = false
                    continue
                }
                if offerTools && settings.toolMode == .auto && rounds == 0 {
                    deps.settingsStore.setToolSupport(true, for: settings.toolSupportKey)
                }
                transcript += roundText
                guard offerTools, !calls.isEmpty else { break }

                rounds += 1
                conversation.append(WireMessage(role: .assistant, content: roundText, toolCalls: calls))
                for call in calls {
                    statusLine = Self.status(for: call)
                    let outcome = AssistantToolbox.execute(call, snapshot: snapshot) { self.format($0, redacts: redacts) }
                    if let proposed = outcome.proposal { proposal = proposed }
                    conversation.append(WireMessage(role: .tool, content: outcome.resultText, toolCallID: call.id, toolName: call.name))
                }
                statusLine = nil
                if !transcript.isEmpty && !transcript.hasSuffix("\n") { transcript += "\n\n" }
            }

            let parsed = PlanParser.extract(from: transcript)
            // The reason is model-authored text, so it may carry folder aliases; the card shows real names.
            let plan = (proposal ?? parsed.proposal).map { proposed -> AssistantPlan in
                var restored = proposed
                restored.reason = display(restored.reason, redacts: redacts)
                return PlanResolver.resolve(restored, in: snapshot)
            }
            let finalText = display(parsed.text, redacts: redacts)
            update(messageID) {
                $0.text = finalText
                $0.plan = plan?.isMeaningful == true ? plan : nil
                $0.planMalformed = proposal == nil && parsed.malformed
                $0.status = .complete
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let llmError = error as? LLMError
            let message = llmError?.userMessage ?? error.localizedDescription
            update(messageID) {
                if cancelled {
                    $0.status = .stopped
                } else {
                    $0.status = $0.text.isEmpty ? .failed : .interrupted
                    $0.errorText = message
                    $0.errorOpensSettings = llmError?.opensSettings ?? false
                }
            }
        }
    }

    private func systemMessages(toolsEnabled: Bool, context: String) -> [WireMessage] {
        [
            WireMessage(role: .system, content: AssistantPrompt.system(toolsEnabled: toolsEnabled)),
            WireMessage(role: .system, content: context),
        ]
    }

    private func wireHistory(excluding id: UUID, redacts: Bool) -> [WireMessage] {
        let history = messages.filter { $0.id != id && !$0.text.isEmpty }.suffix(Self.historyLimit)
        return history.map { message in
            let text = redacts ? redactor.redactText(message.text) : message.text
            return WireMessage(role: message.role == .user ? .user : .assistant, content: text)
        }
    }

    private func toolsEnabled(for settings: AssistantSettings) -> Bool {
        switch settings.toolMode {
        case .on: true
        case .off: false
        case .auto: deps.settingsStore.toolSupport(for: settings.toolSupportKey) ?? true
        }
    }

    // Formats a path or a piece of user-derived text (snapshot lines, item reasons, tool output) for the model.
    // Paths inside the home folder or a registered project root go through `redact`; any other text through `redactText`.
    private func format(_ text: String, redacts: Bool) -> String {
        guard redacts else { return text }
        return redactor.covers(text) ? redactor.redact(text) : redactor.redactText(text)
    }

    private func display(_ text: String, redacts: Bool) -> String {
        redacts ? redactor.restore(text) : text
    }

    private func update(_ id: UUID, _ body: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        body(&messages[index])
    }

    private func persist() {
        deps.conversationStore?.save(messages)
    }

    private static func prepared(_ snapshot: SystemSnapshot, redacts: Bool) -> SystemSnapshot {
        guard redacts, let volume = snapshot.volume, volume.name != "Macintosh HD" else { return snapshot }
        var copy = snapshot
        copy.volume?.name = "системный диск"
        return copy
    }

    private static func status(for call: ToolCall) -> String {
        switch call.name {
        case "list_items": "Смотрю список найденного…"
        case "item_details": "Изучаю элемент…"
        case "propose_plan": "Составляю план…"
        default: "Обрабатываю запрос…"
        }
    }
}
