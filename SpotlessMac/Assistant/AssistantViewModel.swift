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
        var personalRootsProvider: @MainActor () -> [String] = { [] }
        // Bundled read-only articles about macOS; the assistant only ever reads them.
        var knowledge: KnowledgeBase = .empty
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
    private(set) var contextNotice: String?
    private(set) var draftFocus: AssistantFocus?
    var draft = ""
    var isCloudDisclosurePresented = false

    private let deps: Dependencies
    private var redactor: PathRedactor
    private let aliasScope = UUID()
    private var responseID: UUID?
    private var freshUserID: UUID?
    private var checkpointAt: Date?
    private var pendingFocus: AssistantFocus?
    private var pendingText: String?
    private var pendingFromDraft = false
    private var pendingRetry = false
    private var streamTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        deps = dependencies
        settings = dependencies.settingsStore.load()
        hasAPIKey = !dependencies.keyStore.readKey().isEmpty
        messages = dependencies.conversationStore?.load() ?? []
        redactor = PathRedactor(homePath: dependencies.homePath, extraRoots: dependencies.personalRoots + dependencies.personalRootsProvider())
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
        send(text, focus: text == nil ? draftFocus : nil)
    }

    private func send(_ text: String?, focus: AssistantFocus?) {
        let fromDraft = text == nil
        let trimmed = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        planNotice = nil
        // Answered locally: nothing leaves this Mac, so no cloud disclosure is needed either.
        if AssistantGuard.isInjectionAttempt(trimmed) {
            if fromDraft { draft = ""; draftFocus = nil }
            let now = deps.now()
            messages.append(.user(trimmed, at: now))
            messages.append(AssistantMessage(id: UUID(), role: .assistant, text: AssistantGuard.refusal,
                                             status: .complete, createdAt: now))
            persist()
            return
        }
        if needsCloudDisclosure {
            pendingText = trimmed
            pendingFocus = focus
            pendingFromDraft = fromDraft
            pendingRetry = false
            isCloudDisclosurePresented = true
            return
        }
        if fromDraft { draft = ""; draftFocus = nil }
        appendQuestion(trimmed, focus: focus)
        startResponse()
    }

    func ask(about focus: AssistantFocus) {
        // Row shortcuts can fire before the model is set up; the caller switches to the tab,
        // which shows the setup screen. Never queue a hidden exchange or a disclosure here.
        guard isConfigured else { return }
        let question = "Что это и можно ли это удалить?"
        if isStreaming {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = question
                draftFocus = focus
            }
            return
        }
        send(question, focus: focus)
    }

    func clearDraftFocus() { draftFocus = nil }

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
        pendingFocus = nil
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
        responseID = nil
        freshUserID = nil
        streamTask = nil
        isStreaming = false
        statusLine = nil
        pendingText = nil
        pendingFocus = nil
        pendingRetry = false
        draftFocus = nil
        messages = []
        contextNotice = nil
        planNotice = nil
        redactor = PathRedactor(homePath: deps.homePath, extraRoots: deps.personalRoots + deps.personalRootsProvider())
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
        if pendingFromDraft { draft = ""; draftFocus = nil }
        appendQuestion(text, focus: pendingFocus)
        pendingFocus = nil
        startResponse()
    }

    private func appendQuestion(_ text: String, focus: AssistantFocus?) {
        let message = AssistantMessage.user(text, at: deps.now(), focus: focus)
        messages.append(message)
        // Restored/local questions never become eligible merely because Retry made them last.
        freshUserID = settings.sendsDataOffDevice ? message.id : nil
    }

    private struct ResponseConfiguration {
        let settings: AssistantSettings
        let apiKey: String
    }

    private func startResponse() {
        let configuration = ResponseConfiguration(settings: settings, apiKey: deps.keyStore.readKey())
        let current = configuration.settings
        let message = AssistantMessage(id: UUID(), role: .assistant, text: "", status: .streaming,
                                       model: current.trimmedModel, createdAt: deps.now())
        messages.append(message)
        isStreaming = true
        responseID = message.id
        checkpointAt = deps.now()
        persist()
        streamTask = Task { [weak self] in
            await self?.respond(into: message.id, configuration: configuration)
        }
    }

    private func respond(into messageID: UUID, configuration: ResponseConfiguration) async {
        let settings = configuration.settings
        defer {
            if responseID == messageID {
                isStreaming = false
                statusLine = nil
                streamTask = nil
                responseID = nil
                persist()
            }
        }
        let redacts = settings.sendsDataOffDevice
        let tokens = AssistantGuard.Tokens.random()
        await deps.refreshContext()
        let snapshot = Self.prepared(deps.snapshot(), redacts: redacts)
        // Matching runs on real paths; only article ids and article text reach the model.
        let knowledge = KnowledgeContext(
            base: deps.knowledge,
            annotations: KnowledgeMatcher.annotate(snapshot, knowledge: deps.knowledge, homePath: deps.homePath))
        let question = messages.last(where: { $0.role == .user })?.text ?? ""
        do {
            // Stop / new conversation during the context refresh must not render the snapshot
            // (which registers aliases) or open a request.
            try Task.checkCancellation()
            guard responseID == messageID else { return }
            redactor.updateExtraRoots(deps.personalRoots + deps.personalRootsProvider())
            let client = try deps.makeClient(settings, configuration.apiKey)
            var toolsEnabled = toolsEnabled(for: settings)
            // The snapshot does not change within one answer, so it is rendered once. Rendering it
            // first registers folder aliases, so history that names the same folder gets the same alias.
            // File, folder and app names are untrusted: fenced so they read as data, not instructions.
            let context = AssistantGuard.fence(SnapshotRenderer.render(snapshot, knowledge: knowledge) { self.format($0, redacts: redacts) }, tokens: tokens)
            var conversation = wireHistory(excluding: messageID, redacts: redacts, tokens: tokens)
            var transcript = ""
            var rounds = 0
            var proposal: PlanProposal?
            var hasNativeProposal = false

            while true {
                try Task.checkCancellation()
                guard responseID == messageID else { return }
                let offerTools = toolsEnabled && rounds < Self.maxToolRounds
                let request = ChatRequest(
                    model: settings.trimmedModel,
                    messages: systemMessages(toolsEnabled: toolsEnabled, context: context, tokens: tokens, question: question) + conversation,
                    tools: offerTools ? AssistantTool.specs : []
                )
                var roundText = ""
                var calls: [ToolCall] = []
                do {
                    for try await event in client.stream(request) {
                        switch event {
                        case .text(let delta):
                            roundText += delta
                            let visible = PlanParser.visibleWhileStreaming(transcript + roundText)
                            let screened = AssistantGuard.screen(visible, tokens: tokens)
                            let safe = redacts ? redactor.redactText(screened.text) : nil
                            let shown = AssistantGuard.screen(display(screened.text, redacts: redacts), tokens: tokens).text
                            update(messageID) {
                                $0.text = shown
                                $0.outboundSafeText = safe
                                $0.outboundAliasScope = redacts ? aliasScope : nil
                            }
                            checkpoint(messageID)
                        case .toolCalls(let newCalls):
                            calls += newCalls
                        case .done:
                            break
                        }
                    }
                    try Task.checkCancellation()
                } catch LLMError.toolsUnsupported where offerTools && settings.toolMode == .auto && rounds == 0 {
                    try Task.checkCancellation()
                    guard responseID == messageID else { return }
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
                    let outcome = AssistantToolbox.execute(call, snapshot: snapshot, knowledge: knowledge) { self.format($0, redacts: redacts) }
                    if case .replace(let proposed) = outcome.planUpdate {
                        proposal = proposed
                        hasNativeProposal = true
                    }
                    conversation.append(WireMessage(role: .tool, content: AssistantGuard.fence(outcome.resultText, tokens: tokens),
                                                    toolCallID: call.id, toolName: call.name))
                }
                statusLine = nil
                if !transcript.isEmpty && !transcript.hasSuffix("\n") { transcript += "\n\n" }
            }

            let parsed = PlanParser.extract(from: transcript)
            let selectedProposal = hasNativeProposal ? proposal : parsed.proposal
            let rawScreen = AssistantGuard.screenResponse(text: parsed.text, proposal: selectedProposal, tokens: tokens)
            var restored = rawScreen.proposal
            if let reason = restored?.reason { restored?.reason = display(reason, redacts: redacts) }
            let screened = AssistantGuard.screenResponse(text: display(rawScreen.text, redacts: redacts), proposal: restored, tokens: tokens)
            let leaked = rawScreen.leaked || screened.leaked || AssistantGuard.leaksPrompt(transcript, tokens: tokens)
            let plan = leaked ? nil : screened.proposal.map { PlanResolver.resolve($0, in: snapshot) }
            let safe = redacts ? redactor.redactText(leaked ? AssistantGuard.refusal : rawScreen.text) : nil
            update(messageID) {
                $0.text = leaked ? AssistantGuard.refusal : screened.text
                $0.outboundSafeText = safe
                $0.outboundAliasScope = redacts ? aliasScope : nil
                $0.plan = plan?.isMeaningful == true ? plan : nil
                $0.planMalformed = !leaked && !hasNativeProposal && parsed.malformed
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

    private func systemMessages(toolsEnabled: Bool, context: String, tokens: AssistantGuard.Tokens,
                                question: String) -> [WireMessage] {
        var result = [
            WireMessage(role: .system, content: AssistantPrompt.system(toolsEnabled: toolsEnabled, tokens: tokens)),
            WireMessage(role: .system, content: context),
        ]
        // Without tools the model cannot call lookup_knowledge, so the best articles come along.
        // Bundled articles are trusted text, so this message is not fenced.
        if !toolsEnabled, let reference = KnowledgeRenderer.injected(for: question, in: deps.knowledge) {
            result.append(WireMessage(role: .system, content: reference))
        }
        return result
    }

    private func wireHistory(excluding id: UUID, redacts: Bool, tokens: AssistantGuard.Tokens) -> [WireMessage] {
        let history = Self.withoutRefusedExchanges(messages).filter { $0.id != id && !$0.text.isEmpty }.suffix(Self.historyLimit)
        var output: [WireMessage] = []
        contextNotice = nil
        if redacts {
            // Register every reusable full path before redacting older bare-name mentions.
            for message in history {
                if let focus = message.outboundSafeFocus { _ = format(replay(focus.path, scope: message.outboundAliasScope), redacts: true) }
                if let text = message.outboundSafeText { _ = redactor.redactText(replay(text, scope: message.outboundAliasScope)) }
            }
        }
        for message in history {
            var text: String
            var focus: AssistantFocus?
            if redacts {
                if let safe = message.outboundSafeText {
                    text = redactor.redactText(replay(safe, scope: message.outboundAliasScope))
                    focus = message.outboundSafeFocus.map {
                        AssistantFocus(title: format(replay($0.title, scope: message.outboundAliasScope), redacts: true),
                                       path: format(replay($0.path, scope: message.outboundAliasScope), redacts: true),
                                       facts: $0.facts.map { format(replay($0, scope: message.outboundAliasScope), redacts: true) })
                    }
                    update(message.id) {
                        $0.outboundSafeText = text
                        $0.outboundSafeFocus = focus
                        $0.outboundAliasScope = aliasScope
                    }
                } else if message.role == .user && message.id == freshUserID {
                    focus = message.focus.map {
                        // Register full path components before redacting their bare names in
                        // the title, facts or question (the row may not be in the snapshot).
                        let path = format($0.path, redacts: true)
                        return AssistantFocus(title: format($0.title, redacts: true), path: path,
                                              facts: $0.facts.map { format($0, redacts: true) })
                    }
                    text = redactor.redactText(message.text)
                    update(message.id) {
                        $0.outboundSafeText = text
                        $0.outboundSafeFocus = focus
                        $0.outboundAliasScope = aliasScope
                    }
                } else {
                    contextNotice = "Часть истории показана только на этом Mac: безопасный контекст для отправки не сохранён."
                    continue
                }
            } else {
                text = message.text
                focus = message.focus
            }
            if let focus {
                let data = focus.title + "\nПуть: " + focus.path + "\n" + focus.facts.map { "- " + $0 }.joined(separator: "\n")
                text += "\n\n" + AssistantGuard.fence(data, tokens: tokens)
            }
            output.append(WireMessage(role: message.role == .user ? .user : .assistant, content: text))
        }
        freshUserID = nil
        persist()
        return output
    }

    private func replay(_ text: String, scope: UUID?) -> String {
        guard scope != aliasScope else { return text }
        let name = (scope?.uuidString ?? "legacy").lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"<(папка|проекты)-(\d+)>"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "<история-" + name + "-$1-$2>")
    }

    private func checkpoint(_ messageID: UUID) {
        guard responseID == messageID else { return }
        let now = deps.now()
        if checkpointAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
            checkpointAt = now
            persist()
        }
    }

    // A message the input guard flags, and the answer after it, never reach the model.
    private static func withoutRefusedExchanges(_ messages: [AssistantMessage]) -> [AssistantMessage] {
        var kept: [AssistantMessage] = []
        var skipReply = false
        for message in messages {
            if message.role == .user && AssistantGuard.isInjectionAttempt(message.text) {
                skipReply = true
                continue
            }
            if skipReply && message.role == .assistant {
                skipReply = false
                continue
            }
            skipReply = false
            kept.append(message)
        }
        return kept
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
        case "lookup_knowledge": "Читаю справку…"
        default: "Обрабатываю запрос…"
        }
    }
}
