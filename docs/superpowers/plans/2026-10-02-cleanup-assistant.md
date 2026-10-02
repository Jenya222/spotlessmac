# Cleanup Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM-powered cleanup assistant to SpotlessMac: a settings card (Ollama Cloud / local Ollama / OpenAI-compatible, token, model), a chat tab that sees the current scan snapshot, "Ask assistant" on result rows, and plans the user reviews in the existing «Освободить место» preview — with no code path from the assistant to any deletion API.

**Architecture:** A self-contained `SpotlessMac/Assistant/` module (settings, two streaming LLM clients behind `LLMClient`, immutable `SystemSnapshot`, closed tool set, plan parser/resolver, conversation store, `AssistantViewModel`). The module receives only a snapshot closure and a `stagePlan` closure that toggles selection; a source-guard test forbids deletion/process APIs inside the module. Views live in `SpotlessMac/App/`, the snapshot builder in `SpotlessMac/ViewModels/`.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI + Observation, macOS 14, URLSession `bytes(for:)` streaming, XCTest, Keychain via existing `KeychainStore`.

**Spec:** `docs/superpowers/specs/2026-10-02-cleanup-assistant-design.md`

## Prerequisite (before Task 1)

The working tree has many **uncommitted user changes** (ContentView, ScanViewModel, StorageRecoveryView, project.pbxproj, …) that this plan edits. Before Task 1 the human partner must either commit that work-in-progress (recommended: commit it on `main`, then rebase `feature/cleanup-assistant` onto it) or explicitly accept that task commits will include it. Do not start Task 1 until `git status --short` shows only files this plan creates, or the partner has said to proceed.

## Global Constraints

- Xcode 16.2, Swift 6.0 strict concurrency, macOS 14 deployment target. No new third-party dependencies.
- UI strings are Russian, hard-coded in `Text`/labels (no String Catalog), matching existing views.
- The Xcode project does NOT auto-include files. Register every new file: `scripts/xcodeproj-add.py app <Group> <path>` for app code, `scripts/xcodeproj-add.py tests SpotlessMacTests <path>` for tests. Groups used: `Assistant` (created on first use), `App`, `ViewModels`.
- Tests are XCTest (`final class …: XCTestCase`, `@testable import SpotlessMac`). Run via `scripts/test.sh <TestClass> …` (created in Task 1).
- Safety rules from CLAUDE.md stay intact; new rule 6: **the Assistant module never deletes**. Nothing under `SpotlessMac/Assistant/` may contain any of: `trashItem`, `removeItem`, `moveItem`, `copyItem`, `unlink(`, `FileManager` (except `ConversationStore.swift`), `Process(`, `NSWorkspace`, `ScanEngine`, `ScanViewModel`, `DockerCleanupViewModel`, `DockerClient`, `DockerCommandRunner`, `UninstallViewModel`, `UninstallEngine`, `deleteWithProgress`, `cleanCache`, `URL(fileURLWithPath` — **not even in comments**.
- Provider presets: Ollama Cloud `https://ollama.com` (key required), local Ollama `http://localhost:11434` (no key), OpenAI-compatible `https://api.openai.com` (key optional). Default model `gpt-oss:20b` for Ollama providers, empty for OpenAI-compatible. Timeout 10–300 s, default 120.
- Auth header: `Authorization: Bearer <key>`, only when the key is non-empty. Always set `URLRequest.timeoutInterval` explicitly.
- Max 4 tool rounds per answer; history = last 20 messages; ≤150 items and ≤32 000 characters (~8k tokens) of rendered context.
- Cloud (= `AssistantSettings.sendsDataOffDevice`) paths are redacted; local Ollama gets full paths.
- Keychain account for the token: `assistantAPIKey`. UserDefaults keys: `assistantSettings`, `assistantToolSupport`, `assistantCloudDisclosureAccepted`. Conversation file: `~/Library/Application Support/SpotlessMac/assistant-conversation.json`.
- Use `Color.accentColor` explicitly (not `.accentColor`) in `foregroundStyle` (CLAUDE.md Swift 6 tip).

## Review Focus

1. A model that both calls `propose_plan` and appends a `spotless-plan` block → the tool proposal wins, exactly one plan card (test in Task 11).
2. Very large scans (5 000+ items) → rendered context stays under the character budget and says how many items were shown (test in Task 7).
3. Personal paths with spaces and Cyrillic (`~/Documents/Мой проект/…`) → fully redacted by `redact(_:)`, restored in the answer (test in Task 6).
4. "Новый диалог" pressed while an answer is still streaming → no crash, no stale message reappears, streaming flag resets (test in Task 11).
5. Server returns 200 but the stream drops before `done` → partial text kept, message marked `interrupted` with an error text (tests in Tasks 3 and 11).

---

### Task 1: Assistant settings, key store, test runner

**Files:**
- Create: `scripts/test.sh`
- Create: `SpotlessMac/Assistant/AssistantSettings.swift`
- Create: `SpotlessMac/Assistant/APIKeyStore.swift`
- Create: `SpotlessMacTests/AssistantTestSupport.swift`
- Create: `SpotlessMacTests/AssistantSettingsTests.swift`

**Interfaces:**
- Produces: `AssistantProvider` (`.ollamaCloud/.ollamaLocal/.openAICompatible`, `title`, `defaultBaseURL`, `defaultModel`, `usesAPIKey`, `requiresAPIKey`); `AssistantToolMode` (`.auto/.on/.off`, `title`); `struct AssistantSettings: Codable, Equatable, Sendable { provider, baseURL, model, toolMode, timeoutSeconds; static timeoutRange; mutating switchProvider(to:); trimmedModel; sendsDataOffDevice; toolSupportKey }`; `@MainActor final class AssistantSettingsStore { init(defaults:); load(); save(_:); toolSupport(for:) -> Bool?; setToolSupport(_:for:); var cloudDisclosureAccepted }`; `protocol APIKeyStoring: Sendable { readKey() -> String; writeKey(_:) }`; `struct KeychainAPIKeyStore: APIKeyStoring`. Test support: `FakeKeyStore`, `makeDefaults()`.

- [ ] **Step 1: Create the test runner script**

`scripts/test.sh`:
```bash
#!/bin/bash
# Usage: scripts/test.sh [TestClass ...]   (no args = whole SpotlessMacTests target)
set -o pipefail
cd "$(dirname "$0")/.."
args=()
for c in "$@"; do args+=("-only-testing:SpotlessMacTests/$c"); done
xcodebuild test -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO "${args[@]}" 2>&1 \
  | grep -E "error:|Test Case .*(passed|failed)|Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED) \*\*|BUILD FAILED"
```
Run: `chmod +x scripts/test.sh && scripts/test.sh`
Expected: baseline — note the result (`** TEST SUCCEEDED **` or the list of pre-existing failures). Pre-existing failures are not this plan's to fix; record them in the task report.

- [ ] **Step 2: Write test support and failing tests**

`SpotlessMacTests/AssistantTestSupport.swift`:
```swift
import Foundation
@testable import SpotlessMac

final class FakeKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String
    init(_ key: String = "") { self.key = key }
    func readKey() -> String { lock.withLock { key } }
    func writeKey(_ newKey: String) {
        lock.withLock { key = newKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

func makeDefaults() -> UserDefaults {
    let name = "assistant.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
```

`SpotlessMacTests/AssistantSettingsTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

@MainActor
final class AssistantSettingsTests: XCTestCase {
    func testDefaultsAreOllamaCloudWithGptOss() {
        let settings = AssistantSettings()
        XCTAssertEqual(settings.provider, .ollamaCloud)
        XCTAssertEqual(settings.baseURL, "https://ollama.com")
        XCTAssertEqual(settings.model, "gpt-oss:20b")
        XCTAssertEqual(settings.toolMode, .auto)
        XCTAssertEqual(settings.timeoutSeconds, 120)
    }

    func testSwitchProviderAppliesPresets() {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        XCTAssertEqual(settings.baseURL, "http://localhost:11434")
        XCTAssertEqual(settings.model, "gpt-oss:20b")
        settings.switchProvider(to: .openAICompatible)
        XCTAssertEqual(settings.baseURL, "https://api.openai.com")
        XCTAssertEqual(settings.model, "")
    }

    func testSendsDataOffDevice() {
        var settings = AssistantSettings()
        XCTAssertTrue(settings.sendsDataOffDevice)
        settings.switchProvider(to: .ollamaLocal)
        XCTAssertFalse(settings.sendsDataOffDevice)
        settings.switchProvider(to: .openAICompatible)
        XCTAssertTrue(settings.sendsDataOffDevice)
        settings.baseURL = "http://localhost:1234"
        XCTAssertFalse(settings.sendsDataOffDevice)
        settings.baseURL = "http://127.0.0.1:1234"
        XCTAssertFalse(settings.sendsDataOffDevice)
    }

    func testKeyRequirements() {
        XCTAssertTrue(AssistantProvider.ollamaCloud.requiresAPIKey)
        XCTAssertFalse(AssistantProvider.ollamaLocal.usesAPIKey)
        XCTAssertTrue(AssistantProvider.openAICompatible.usesAPIKey)
        XCTAssertFalse(AssistantProvider.openAICompatible.requiresAPIKey)
    }

    func testStoreRoundTripAndClampsTimeout() {
        let store = AssistantSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), AssistantSettings())
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        settings.model = "qwen3:8b"
        settings.timeoutSeconds = 9_999
        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.provider, .ollamaLocal)
        XCTAssertEqual(loaded.model, "qwen3:8b")
        XCTAssertEqual(loaded.timeoutSeconds, 300)
    }

    func testToolSupportCacheAndDisclosureFlag() {
        let store = AssistantSettingsStore(defaults: makeDefaults())
        let key = AssistantSettings().toolSupportKey
        XCTAssertNil(store.toolSupport(for: key))
        store.setToolSupport(false, for: key)
        XCTAssertEqual(store.toolSupport(for: key), false)
        XCTAssertFalse(store.cloudDisclosureAccepted)
        store.cloudDisclosureAccepted = true
        XCTAssertTrue(store.cloudDisclosureAccepted)
    }

    func testFakeKeyStoreTrims() {
        let keys = FakeKeyStore()
        keys.writeKey("  abc \n")
        XCTAssertEqual(keys.readKey(), "abc")
    }
}
```

- [ ] **Step 3: Register files and run to verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantTestSupport.swift SpotlessMacTests/AssistantSettingsTests.swift
scripts/test.sh AssistantSettingsTests
```
Expected: build errors `cannot find type 'APIKeyStoring'` / `'AssistantSettings'`.

- [ ] **Step 4: Implement**

`SpotlessMac/Assistant/AssistantSettings.swift`:
```swift
import Foundation

enum AssistantProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollamaCloud, ollamaLocal, openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollamaCloud: "Ollama Cloud"
        case .ollamaLocal: "Локальная Ollama"
        case .openAICompatible: "OpenAI-совместимый"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollamaCloud: "https://ollama.com"
        case .ollamaLocal: "http://localhost:11434"
        case .openAICompatible: "https://api.openai.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .ollamaCloud, .ollamaLocal: "gpt-oss:20b"
        case .openAICompatible: ""
        }
    }

    var usesAPIKey: Bool { self != .ollamaLocal }
    var requiresAPIKey: Bool { self == .ollamaCloud }
}

enum AssistantToolMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, on, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Авто"
        case .on: "Вкл"
        case .off: "Выкл"
        }
    }
}

struct AssistantSettings: Codable, Equatable, Sendable {
    static let timeoutRange = 10...300

    var provider: AssistantProvider = .ollamaCloud
    var baseURL: String = AssistantProvider.ollamaCloud.defaultBaseURL
    var model: String = AssistantProvider.ollamaCloud.defaultModel
    var toolMode: AssistantToolMode = .auto
    var timeoutSeconds: Int = 120

    mutating func switchProvider(to newProvider: AssistantProvider) {
        provider = newProvider
        baseURL = newProvider.defaultBaseURL
        model = newProvider.defaultModel
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Anything that leaves this Mac gets redacted paths.
    var sendsDataOffDevice: Bool {
        switch provider {
        case .ollamaCloud: return true
        case .ollamaLocal: return false
        case .openAICompatible:
            let host = URL(string: baseURL)?.host()?.lowercased() ?? ""
            return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }
    }

    var toolSupportKey: String { "\(provider.rawValue)|\(baseURL)|\(trimmedModel)" }
}

@MainActor
final class AssistantSettingsStore {
    private let defaults: UserDefaults
    private let settingsKey = "assistantSettings"
    private let toolSupportKey = "assistantToolSupport"
    private let disclosureKey = "assistantCloudDisclosureAccepted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AssistantSettings {
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(AssistantSettings.self, from: data) else {
            return AssistantSettings()
        }
        let range = AssistantSettings.timeoutRange
        settings.timeoutSeconds = min(max(settings.timeoutSeconds, range.lowerBound), range.upperBound)
        return settings
    }

    func save(_ settings: AssistantSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    func toolSupport(for key: String) -> Bool? {
        (defaults.dictionary(forKey: toolSupportKey) as? [String: Bool])?[key]
    }

    func setToolSupport(_ supported: Bool, for key: String) {
        var map = (defaults.dictionary(forKey: toolSupportKey) as? [String: Bool]) ?? [:]
        map[key] = supported
        defaults.set(map, forKey: toolSupportKey)
    }

    var cloudDisclosureAccepted: Bool {
        get { defaults.bool(forKey: disclosureKey) }
        set { defaults.set(newValue, forKey: disclosureKey) }
    }
}
```

`SpotlessMac/Assistant/APIKeyStore.swift`:
```swift
import Foundation

protocol APIKeyStoring: Sendable {
    func readKey() -> String
    func writeKey(_ key: String)
}

struct KeychainAPIKeyStore: APIKeyStoring {
    private let account = "assistantAPIKey"

    func readKey() -> String {
        KeychainStore.read(account: account).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // An empty key removes the Keychain item.
    func writeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: account)
        } else {
            KeychainStore.write(Data(trimmed.utf8), account: account)
        }
    }
}
```

- [ ] **Step 5: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantSettings.swift SpotlessMac/Assistant/APIKeyStore.swift
scripts/test.sh AssistantSettingsTests
```
Expected: `Executed 7 tests, with 0 failures`, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add scripts/test.sh SpotlessMac/Assistant SpotlessMacTests/AssistantTestSupport.swift SpotlessMacTests/AssistantSettingsTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): settings, Keychain key store, test runner"
```

---

### Task 2: LLM wire types, errors, HTTP transport

**Files:**
- Create: `SpotlessMac/Assistant/LLMTypes.swift`
- Create: `SpotlessMac/Assistant/LLMError.swift`
- Create: `SpotlessMac/Assistant/HTTPTransport.swift`
- Modify: `SpotlessMacTests/AssistantTestSupport.swift` (append fakes)
- Create: `SpotlessMacTests/LLMErrorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum ChatRole: String { system, user, assistant, tool }`
  - `struct ToolCall: Codable, Equatable, Sendable { id, name, argumentsJSON: String }`
  - `struct WireMessage: Equatable, Sendable { role: ChatRole; content: String; toolCalls: [ToolCall] = []; toolCallID: String?; toolName: String? }`
  - `struct ToolSpec: Equatable, Sendable { name, description, parametersJSON; func jsonObject() -> [String: Any] }`
  - `struct ChatRequest: Sendable { model; messages: [WireMessage]; tools: [ToolSpec] = []; temperature: Double = 0.2 }`
  - `enum ChatEvent: Equatable, Sendable { text(String), toolCalls([ToolCall]), done }`
  - `protocol LLMClient: Sendable { stream(_:) -> AsyncThrowingStream<ChatEvent, Error>; listModels() async throws -> [String] }`
  - `enum JSONText { string(from: Any) -> String; object(from: String) -> Any? }`
  - `enum LLMError: Error, Equatable, Sendable` with `userMessage`, `opensSettings`, `static fromHTTP(status:body:)`, `static mapTransport(_:host:timeout:) -> Error`, `static extractMessage(from:) -> String`
  - `extension URL { var hostLabel: String }`
  - `struct HTTPStreamResponse { statusCode; lines; collectBody(limit:) }`, `protocol HTTPTransport: Sendable { open(_:) async throws -> HTTPStreamResponse }`, `struct URLSessionTransport: HTTPTransport`
  - Test support: `FakeTransport` (with `Reply`), `FakeLLMClient` (with `Step`), `jsonBody(_:)`, `collectEvents(_:)`.

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/LLMErrorTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class LLMErrorTests: XCTestCase {
    func testHTTPStatusMapping() {
        XCTAssertEqual(LLMError.fromHTTP(status: 401, body: ""), .unauthorized)
        XCTAssertEqual(LLMError.fromHTTP(status: 403, body: ""), .unauthorized)
        XCTAssertEqual(LLMError.fromHTTP(status: 404, body: ""), .modelNotFound)
        XCTAssertEqual(LLMError.fromHTTP(status: 429, body: ""), .rateLimited)
        XCTAssertEqual(LLMError.fromHTTP(status: 500, body: "boom"), .httpStatus(code: 500, body: "boom"))
    }

    func testToolsUnsupportedDetectedFromBody() {
        XCTAssertEqual(LLMError.fromHTTP(status: 400, body: #"{"error":"registry.ollama.ai/library/gemma:2b does not support tools"}"#), .toolsUnsupported)
        XCTAssertEqual(LLMError.fromHTTP(status: 400, body: #"{"error":{"message":"This model does not support tools"}}"#), .toolsUnsupported)
    }

    func testModelNotFoundDetectedFromBody() {
        XCTAssertEqual(LLMError.fromHTTP(status: 500, body: "model 'nope' not found"), .modelNotFound)
    }

    func testBodyIsTruncated() {
        let long = String(repeating: "x", count: 1_000)
        guard case .httpStatus(_, let body) = LLMError.fromHTTP(status: 502, body: long) else { return XCTFail() }
        XCTAssertEqual(body.count, 240)
    }

    func testExtractMessageHandlesBothShapes() {
        XCTAssertEqual(LLMError.extractMessage(from: #"{"error":"plain"}"#), "plain")
        XCTAssertEqual(LLMError.extractMessage(from: #"{"error":{"message":"nested"}}"#), "nested")
        XCTAssertEqual(LLMError.extractMessage(from: "not json"), "not json")
    }

    func testTransportMapping() {
        XCTAssertEqual(LLMError.mapTransport(URLError(.cannotConnectToHost), host: "localhost:11434", timeout: 60) as? LLMError, .connectionRefused(host: "localhost:11434"))
        XCTAssertEqual(LLMError.mapTransport(URLError(.timedOut), host: "h", timeout: 60) as? LLMError, .timedOut(seconds: 60))
        XCTAssertTrue(LLMError.mapTransport(URLError(.cancelled), host: "h", timeout: 60) is CancellationError)
        XCTAssertEqual(LLMError.mapTransport(LLMError.rateLimited, host: "h", timeout: 1) as? LLMError, .rateLimited)
    }

    func testUserMessagesAndSettingsHint() {
        XCTAssertTrue(LLMError.unauthorized.userMessage.contains("Неверный токен"))
        XCTAssertTrue(LLMError.connectionRefused(host: "localhost:11434").userMessage.contains("ollama serve"))
        XCTAssertTrue(LLMError.timedOut(seconds: 30).userMessage.contains("30"))
        XCTAssertTrue(LLMError.unauthorized.opensSettings)
        XCTAssertTrue(LLMError.missingAPIKey.opensSettings)
        XCTAssertFalse(LLMError.rateLimited.opensSettings)
    }

    func testHostLabel() {
        XCTAssertEqual(URL(string: "http://localhost:11434")!.hostLabel, "localhost:11434")
        XCTAssertEqual(URL(string: "https://ollama.com")!.hostLabel, "ollama.com")
    }
}
```

Append to `SpotlessMacTests/AssistantTestSupport.swift`:
```swift
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var lines: [String] = []
        var error: Error?
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? Reply() : replies.removeFirst()
        }
        if let error = reply.error { throw error }
        let lines = reply.lines
        return HTTPStreamResponse(statusCode: reply.status, lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}

final class FakeLLMClient: LLMClient, @unchecked Sendable {
    enum Step {
        case events([ChatEvent])
        case failure(Error)
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [ChatRequest] = []
    private var hanging: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    var models: [String] = []

    init(_ steps: [Step]) { self.steps = steps }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let step: Step = lock.withLock {
            recorded.append(request)
            return steps.isEmpty ? .events([.done]) : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .hang:
                // Kept alive on purpose: the stream ends only when the consumer is cancelled.
                lock.withLock { hanging.append(continuation) }
            }
        }
    }

    func listModels() async throws -> [String] { models }
}

func jsonBody(_ request: URLRequest) -> [String: Any] {
    (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

func collectEvents(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/LLMErrorTests.swift
scripts/test.sh LLMErrorTests
```
Expected: build errors `cannot find type 'LLMError'`, `'HTTPTransport'`, `'ChatEvent'`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/LLMTypes.swift`:
```swift
import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct WireMessage: Equatable, Sendable {
    let role: ChatRole
    let content: String
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var toolName: String?
}

struct ToolSpec: Equatable, Sendable {
    let name: String
    let description: String
    let parametersJSON: String

    // Same function-tool shape for Ollama /api/chat and OpenAI /v1/chat/completions.
    func jsonObject() -> [String: Any] {
        let parameters = JSONText.object(from: parametersJSON) ?? ["type": "object", "properties": [String: Any]()]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

struct ChatRequest: Sendable {
    var model: String
    var messages: [WireMessage]
    var tools: [ToolSpec] = []
    var temperature: Double = 0.2
}

enum ChatEvent: Equatable, Sendable {
    case text(String)
    case toolCalls([ToolCall])
    case done
}

protocol LLMClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func listModels() async throws -> [String]
}

enum JSONText {
    static func string(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(from text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
```

`SpotlessMac/Assistant/LLMError.swift`:
```swift
import Foundation

enum LLMError: Error, Equatable, Sendable {
    case missingAPIKey
    case unauthorized
    case modelNotFound
    case rateLimited
    case toolsUnsupported
    case connectionRefused(host: String)
    case timedOut(seconds: Int)
    case httpStatus(code: Int, body: String)
    case decodingFailed
    case invalidURL
    case streamInterrupted

    var userMessage: String {
        switch self {
        case .missingAPIKey: "Не указан токен. Добавьте его в Настройки → Ассистент."
        case .unauthorized: "Неверный токен. Проверьте его в Настройки → Ассистент."
        case .modelNotFound: "Модель не найдена. Выберите другую в настройках."
        case .rateLimited: "Превышен лимит запросов. Попробуйте позже."
        case .toolsUnsupported: "Модель не поддерживает инструменты. Выключите их в настройках."
        case .connectionRefused(let host):
            "Не удалось подключиться к \(host). Если это локальная Ollama — запустите приложение Ollama или `ollama serve`."
        case .timedOut(let seconds): "Модель не ответила за \(seconds) с. Увеличьте тайм-аут в настройках."
        case .httpStatus(let code, let body): body.isEmpty ? "Сервер вернул ошибку \(code)." : "Сервер вернул ошибку \(code): \(body)"
        case .decodingFailed: "Не удалось разобрать ответ сервера."
        case .invalidURL: "Некорректный адрес сервера. Проверьте URL в настройках."
        case .streamInterrupted: "Ответ прерван: соединение закрылось раньше времени."
        }
    }

    var opensSettings: Bool {
        switch self {
        case .missingAPIKey, .unauthorized, .modelNotFound, .invalidURL, .toolsUnsupported: true
        default: false
        }
    }

    static func fromHTTP(status: Int, body: String) -> LLMError {
        let message = extractMessage(from: body)
        let lower = message.lowercased()
        if lower.contains("tool"), lower.contains("support") { return .toolsUnsupported }
        if lower.contains("model"), lower.contains("not found") { return .modelNotFound }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .modelNotFound
        case 429: return .rateLimited
        default: return .httpStatus(code: status, body: String(message.prefix(240)))
        }
    }

    // Ollama: {"error":"…"}; OpenAI-compatible: {"error":{"message":"…"}}.
    static func extractMessage(from body: String) -> String {
        guard let json = JSONText.object(from: body) as? [String: Any] else { return body }
        if let text = json["error"] as? String { return text }
        if let nested = json["error"] as? [String: Any], let text = nested["message"] as? String { return text }
        return body
    }

    static func mapTransport(_ error: Error, host: String, timeout: Int) -> Error {
        if error is LLMError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet: return LLMError.connectionRefused(host: host)
        case .timedOut: return LLMError.timedOut(seconds: timeout)
        case .networkConnectionLost: return LLMError.streamInterrupted
        default: return LLMError.httpStatus(code: urlError.errorCode, body: urlError.localizedDescription)
        }
    }
}

extension URL {
    var hostLabel: String {
        let host = host() ?? absoluteString
        return port.map { "\(host):\($0)" } ?? host
    }
}
```

`SpotlessMac/Assistant/HTTPTransport.swift`:
```swift
import Foundation

struct HTTPStreamResponse: Sendable {
    let statusCode: Int
    let lines: AsyncThrowingStream<String, Error>

    func collectBody(limit: Int = 4_000) async throws -> String {
        var body = ""
        for try await line in lines {
            body += body.isEmpty ? line : "\n" + line
            if body.count >= limit { break }
        }
        return body
    }
}

protocol HTTPTransport: Sendable {
    func open(_ request: URLRequest) async throws -> HTTPStreamResponse
}

struct URLSessionTransport: HTTPTransport {
    func open(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // AsyncBytes is consumed only by the task below.
        nonisolated(unsafe) let source = bytes
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in source.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(statusCode: status, lines: lines)
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/LLMTypes.swift SpotlessMac/Assistant/LLMError.swift SpotlessMac/Assistant/HTTPTransport.swift
scripts/test.sh LLMErrorTests AssistantSettingsTests
```
Expected: all pass, `** TEST SUCCEEDED **`. If the compiler rejects `nonisolated(unsafe) let` for a local, change the line to `nonisolated(unsafe) var source = bytes` and re-run.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/AssistantTestSupport.swift SpotlessMacTests/LLMErrorTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): LLM wire types, error mapping, streaming transport"
```

---

### Task 3: Ollama client (`/api/chat` NDJSON, `/api/tags`)

**Files:**
- Create: `SpotlessMac/Assistant/OllamaClient.swift`
- Create: `SpotlessMacTests/OllamaClientTests.swift`

**Interfaces:**
- Consumes: Task 2 types (`LLMClient`, `ChatRequest`, `ChatEvent`, `ToolCall`, `WireMessage`, `ToolSpec.jsonObject()`, `JSONText`, `LLMError`, `HTTPTransport`, `URL.hostLabel`).
- Produces: `struct OllamaClient: LLMClient { baseURL: URL; apiKey: String; timeout: TimeInterval; transport: HTTPTransport; func makeChatRequest(_:) throws -> URLRequest }`.

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/OllamaClientTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class OllamaClientTests: XCTestCase {
    private let cloud = URL(string: "https://ollama.com")!
    private let tool = ToolSpec(name: "list_items", description: "d", parametersJSON: #"{"type":"object","properties":{}}"#)

    private func request(tools: [ToolSpec] = []) -> ChatRequest {
        ChatRequest(model: "gpt-oss:20b", messages: [WireMessage(role: .system, content: "sys"), WireMessage(role: .user, content: "hi")], tools: tools)
    }

    func testChatRequestBodyAndHeaders() async throws {
        let transport = FakeTransport([.init(lines: [#"{"message":{"role":"assistant","content":"ok"},"done":true}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "secret", timeout: 90, transport: transport)
        _ = try await collectEvents(client.stream(request(tools: [tool])))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://ollama.com/api/chat")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.timeoutInterval, 90)
        let body = jsonBody(sent)
        XCTAssertEqual(body["model"] as? String, "gpt-oss:20b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }, ["system", "user"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["function"] as? [String: Any])?["name"] as? String, "list_items")
    }

    func testNoAuthorizationAndNoToolsWhenEmpty() async throws {
        let transport = FakeTransport([.init(lines: [#"{"done":true}"#])])
        let client = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, apiKey: "", timeout: 30, transport: transport)
        _ = try await collectEvents(client.stream(request()))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(jsonBody(sent)["tools"])
    }

    func testToolMessagesAreEncoded() throws {
        let client = OllamaClient(baseURL: cloud, apiKey: "", timeout: 30, transport: FakeTransport([]))
        let call = ToolCall(id: "call_1", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)
        let req = ChatRequest(model: "m", messages: [
            WireMessage(role: .assistant, content: "", toolCalls: [call]),
            WireMessage(role: .tool, content: "result", toolCallID: "call_1", toolName: "list_items"),
        ])
        let messages = try XCTUnwrap(jsonBody(client.makeChatRequest(req))["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "list_items")
        XCTAssertEqual((function["arguments"] as? [String: Any])?["category"] as? String, "logs")
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_name"] as? String, "list_items")
    }

    func testParsesTextToolCallsAndDone() async throws {
        let transport = FakeTransport([.init(lines: [
            #"{"message":{"role":"assistant","content":"При"},"done":false}"#,
            "",
            #"{"message":{"role":"assistant","content":"вет"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"list_items","arguments":{"category":"logs"}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true}"#,
        ])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        let events = try await collectEvents(client.stream(request()))
        XCTAssertEqual(events, [
            .text("При"), .text("вет"),
            .toolCalls([ToolCall(id: "call_1", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)]),
            .done,
        ])
    }

    func testToolsUnsupportedStatus() async {
        let transport = FakeTransport([.init(status: 400, lines: [#"{"error":"registry.ollama.ai/library/gemma:2b does not support tools"}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request(tools: [tool])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .toolsUnsupported)
        }
    }

    func testErrorLineInsideStream() async {
        let transport = FakeTransport([.init(lines: [#"{"error":"model 'nope' not found"}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request()))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .modelNotFound)
        }
    }

    // Review focus 5: 200 response that ends without "done".
    func testStreamWithoutDoneIsInterrupted() async {
        let transport = FakeTransport([.init(lines: [#"{"message":{"content":"Частичный"},"done":false}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        var received: [ChatEvent] = []
        do {
            for try await event in client.stream(request()) { received.append(event) }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(received, [.text("Частичный")])
            XCTAssertEqual(error as? LLMError, .streamInterrupted)
        }
    }

    func testConnectionRefused() async {
        let transport = FakeTransport([.init(error: URLError(.cannotConnectToHost))])
        let client = OllamaClient(baseURL: URL(string: "http://localhost:11434")!, apiKey: "", timeout: 30, transport: transport)
        do {
            _ = try await collectEvents(client.stream(request()))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .connectionRefused(host: "localhost:11434"))
        }
    }

    func testListModels() async throws {
        let transport = FakeTransport([.init(lines: [#"{"models":[{"name":"qwen3:8b"},{"name":"gpt-oss:20b"}]}"#])])
        let client = OllamaClient(baseURL: cloud, apiKey: "k", timeout: 30, transport: transport)
        let models = try await client.listModels()
        XCTAssertEqual(models, ["gpt-oss:20b", "qwen3:8b"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://ollama.com/api/tags")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/OllamaClientTests.swift
scripts/test.sh OllamaClientTests
```
Expected: build error `cannot find 'OllamaClient' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/OllamaClient.swift`:
```swift
import Foundation

struct OllamaClient: LLMClient {
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval
    let transport: HTTPTransport

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.open(try makeChatRequest(request))
                    guard (200..<300).contains(response.statusCode) else {
                        throw LLMError.fromHTTP(status: response.statusCode, body: try await response.collectBody())
                    }
                    var callCount = 0
                    for try await line in response.lines {
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        guard let chunk = JSONText.object(from: line) as? [String: Any] else { throw LLMError.decodingFailed }
                        if let message = chunk["error"] as? String {
                            throw LLMError.fromHTTP(status: 500, body: message)
                        }
                        let message = chunk["message"] as? [String: Any]
                        if let content = message?["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        if let rawCalls = message?["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                            var calls: [ToolCall] = []
                            for raw in rawCalls {
                                guard let function = raw["function"] as? [String: Any],
                                      let name = function["name"] as? String else { continue }
                                callCount += 1
                                let arguments = function["arguments"] as? String
                                    ?? JSONText.string(from: function["arguments"] ?? [String: Any]())
                                calls.append(ToolCall(id: "call_\(callCount)", name: name, argumentsJSON: arguments))
                            }
                            if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                        }
                        if chunk["done"] as? Bool == true {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                    }
                    try Task.checkCancellation()
                    throw LLMError.streamInterrupted
                } catch {
                    continuation.finish(throwing: LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        authorize(&request)
        do {
            let response = try await transport.open(request)
            let body = try await response.collectBody(limit: 2_000_000)
            guard (200..<300).contains(response.statusCode) else {
                throw LLMError.fromHTTP(status: response.statusCode, body: body)
            }
            guard let json = JSONText.object(from: body) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { throw LLMError.decodingFailed }
            return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }.sorted()
        } catch {
            throw LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout))
        }
    }

    func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "messages": request.messages.map(Self.wire),
            "options": ["temperature": request.temperature],
        ]
        if !request.tools.isEmpty { body["tools"] = request.tools.map { $0.jsonObject() } }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func wire(_ message: WireMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                ["function": ["name": call.name, "arguments": JSONText.object(from: call.argumentsJSON) ?? [String: Any]()]]
            }
        }
        if message.role == .tool, let name = message.toolName { object["tool_name"] = name }
        return object
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/OllamaClient.swift
scripts/test.sh OllamaClientTests
```
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/OllamaClient.swift SpotlessMacTests/OllamaClientTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): streaming Ollama client with tool calls"
```

---

### Task 4: OpenAI-compatible client (`/v1/chat/completions` SSE, `/v1/models`)

**Files:**
- Create: `SpotlessMac/Assistant/OpenAICompatibleClient.swift`
- Create: `SpotlessMacTests/OpenAICompatibleClientTests.swift`

**Interfaces:**
- Consumes: Task 2 types.
- Produces: `struct OpenAICompatibleClient: LLMClient { baseURL; apiKey; timeout; transport; func makeChatRequest(_:) throws -> URLRequest }`.

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/OpenAICompatibleClientTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class OpenAICompatibleClientTests: XCTestCase {
    private let base = URL(string: "https://api.openai.com")!

    private func client(_ transport: FakeTransport, key: String = "sk") -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: base, apiKey: key, timeout: 45, transport: transport)
    }

    func testRequestShape() throws {
        let call = ToolCall(id: "call_a", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)
        let req = ChatRequest(model: "gpt-4o-mini", messages: [
            WireMessage(role: .user, content: "hi"),
            WireMessage(role: .assistant, content: "", toolCalls: [call]),
            WireMessage(role: .tool, content: "r", toolCallID: "call_a", toolName: "list_items"),
        ], tools: [ToolSpec(name: "list_items", description: "d", parametersJSON: #"{"type":"object"}"#)])
        let sent = try client(FakeTransport([])).makeChatRequest(req)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk")
        XCTAssertEqual(sent.timeoutInterval, 45)
        let body = jsonBody(sent)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_a")
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"category":"logs"}"#)
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "call_a")
        XCTAssertNotNil(body["tools"])
    }

    func testNoAuthorizationWithoutKey() throws {
        let sent = try client(FakeTransport([]), key: "").makeChatRequest(ChatRequest(model: "m", messages: []))
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
    }

    func testParsesSSEText() async throws {
        let transport = FakeTransport([.init(lines: [
            #"data: {"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#,
            ": keep-alive",
            #"data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])])
        let events = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
        XCTAssertEqual(events, [.text("Hel"), .text("lo"), .done])
    }

    func testAccumulatesChunkedToolCalls() async throws {
        let transport = FakeTransport([.init(lines: [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"list_items","arguments":"{\"cate"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"gory\":\"logs\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])])
        let events = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
        XCTAssertEqual(events, [
            .toolCalls([ToolCall(id: "call_a", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)]),
            .done,
        ])
    }

    func testToolsUnsupported() async {
        let transport = FakeTransport([.init(status: 400, lines: [#"{"error":{"message":"This model does not support tools"}}"#])])
        do {
            _ = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .toolsUnsupported)
        }
    }

    func testStreamWithoutDoneIsInterrupted() async {
        let transport = FakeTransport([.init(lines: [#"data: {"choices":[{"delta":{"content":"x"}}]}"#])])
        do {
            _ = try await collectEvents(client(transport).stream(ChatRequest(model: "m", messages: [])))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .streamInterrupted)
        }
    }

    func testListModels() async throws {
        let transport = FakeTransport([.init(lines: [#"{"data":[{"id":"b"},{"id":"a"}]}"#])])
        let models = try await client(transport).listModels()
        XCTAssertEqual(models, ["a", "b"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.openai.com/v1/models")
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/OpenAICompatibleClientTests.swift
scripts/test.sh OpenAICompatibleClientTests
```
Expected: build error `cannot find 'OpenAICompatibleClient' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/OpenAICompatibleClient.swift`:
```swift
import Foundation

struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let apiKey: String
    let timeout: TimeInterval
    let transport: HTTPTransport

    private struct PendingCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await transport.open(try makeChatRequest(request))
                    guard (200..<300).contains(response.statusCode) else {
                        throw LLMError.fromHTTP(status: response.statusCode, body: try await response.collectBody())
                    }
                    var pending: [Int: PendingCall] = [:]
                    for try await rawLine in response.lines {
                        let line = rawLine.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            if let calls = Self.drain(&pending) { continuation.yield(.toolCalls(calls)) }
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }
                        guard let chunk = JSONText.object(from: payload) as? [String: Any] else { throw LLMError.decodingFailed }
                        if chunk["error"] != nil {
                            throw LLMError.fromHTTP(status: 500, body: payload)
                        }
                        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any]
                        if let content = delta?["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        for raw in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                            let index = raw["index"] as? Int ?? 0
                            var entry = pending[index] ?? PendingCall()
                            if let id = raw["id"] as? String { entry.id = id }
                            let function = raw["function"] as? [String: Any]
                            if let name = function?["name"] as? String { entry.name += name }
                            if let arguments = function?["arguments"] as? String { entry.arguments += arguments }
                            pending[index] = entry
                        }
                        if choice["finish_reason"] as? String == "tool_calls", let calls = Self.drain(&pending) {
                            continuation.yield(.toolCalls(calls))
                        }
                    }
                    try Task.checkCancellation()
                    throw LLMError.streamInterrupted
                } catch {
                    continuation.finish(throwing: LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        authorize(&request)
        do {
            let response = try await transport.open(request)
            let body = try await response.collectBody(limit: 2_000_000)
            guard (200..<300).contains(response.statusCode) else {
                throw LLMError.fromHTTP(status: response.statusCode, body: body)
            }
            guard let json = JSONText.object(from: body) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { throw LLMError.decodingFailed }
            return models.compactMap { $0["id"] as? String }.sorted()
        } catch {
            throw LLMError.mapTransport(error, host: baseURL.hostLabel, timeout: Int(timeout))
        }
    }

    func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        var body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "temperature": request.temperature,
            "messages": request.messages.map(Self.wire),
        ]
        if !request.tools.isEmpty { body["tools"] = request.tools.map { $0.jsonObject() } }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func drain(_ pending: inout [Int: PendingCall]) -> [ToolCall]? {
        guard !pending.isEmpty else { return nil }
        let calls = pending.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = pending[index], !call.name.isEmpty else { return nil }
            return ToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name,
                            argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        }
        pending = [:]
        return calls.isEmpty ? nil : calls
    }

    private static func wire(_ message: WireMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
        }
        if message.role == .tool, let id = message.toolCallID { object["tool_call_id"] = id }
        return object
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/OpenAICompatibleClient.swift
scripts/test.sh OpenAICompatibleClientTests
```
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/OpenAICompatibleClient.swift SpotlessMacTests/OpenAICompatibleClientTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): streaming OpenAI-compatible client"
```

---

### Task 5: Client factory and connection tester

**Files:**
- Create: `SpotlessMac/Assistant/LLMClientFactory.swift`
- Create: `SpotlessMac/Assistant/AssistantConnectionTester.swift`
- Create: `SpotlessMacTests/LLMClientFactoryTests.swift`

**Interfaces:**
- Consumes: `AssistantSettings` (Task 1), clients (Tasks 3–4), `FakeLLMClient` (Task 2).
- Produces:
  - `enum LLMClientFactory { static func make(settings: AssistantSettings, apiKey: String, transport: HTTPTransport = URLSessionTransport()) throws -> any LLMClient; static func normalizedBaseURL(_ text: String, provider: AssistantProvider) -> URL? }`
  - `struct ConnectionCheckResult: Equatable, Sendable { ok: Bool; message: String; toolsSupported: Bool?; static func failure(_ error: Error) -> ConnectionCheckResult }`
  - `enum AssistantConnectionTester { static func check(client: any LLMClient, model: String) async -> ConnectionCheckResult }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/LLMClientFactoryTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class LLMClientFactoryTests: XCTestCase {
    func testCloudWithoutKeyThrows() {
        XCTAssertThrowsError(try LLMClientFactory.make(settings: AssistantSettings(), apiKey: " ")) { error in
            XCTAssertEqual(error as? LLMError, .missingAPIKey)
        }
    }

    func testLocalOllamaDropsKey() throws {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        let client = try XCTUnwrap(try LLMClientFactory.make(settings: settings, apiKey: "leftover") as? OllamaClient)
        XCTAssertEqual(client.apiKey, "")
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(client.timeout, 120)
    }

    func testOpenAICompatibleStripsV1Suffix() throws {
        var settings = AssistantSettings()
        settings.switchProvider(to: .openAICompatible)
        settings.baseURL = "http://localhost:1234/v1/"
        let client = try XCTUnwrap(try LLMClientFactory.make(settings: settings, apiKey: "") as? OpenAICompatibleClient)
        XCTAssertEqual(client.baseURL.absoluteString, "http://localhost:1234")
    }

    func testOllamaStripsApiSuffix() {
        XCTAssertEqual(LLMClientFactory.normalizedBaseURL("https://ollama.com/api", provider: .ollamaCloud)?.absoluteString, "https://ollama.com")
    }

    func testInvalidURLThrows() {
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        for bad in ["", "not a url", "ftp://host"] {
            settings.baseURL = bad
            XCTAssertThrowsError(try LLMClientFactory.make(settings: settings, apiKey: "")) { error in
                XCTAssertEqual(error as? LLMError, .invalidURL, bad)
            }
        }
    }

    func testTesterReportsToolSupport() async {
        let client = FakeLLMClient([.events([.text("готово"), .done])])
        let result = await AssistantConnectionTester.check(client: client, model: "gpt-oss:20b")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.toolsSupported, true)
        XCTAssertTrue(result.message.contains("gpt-oss:20b"))
        XCTAssertFalse(client.requests[0].tools.isEmpty)
    }

    func testTesterFallsBackWhenToolsUnsupported() async {
        let client = FakeLLMClient([.failure(LLMError.toolsUnsupported), .events([.text("ok"), .done])])
        let result = await AssistantConnectionTester.check(client: client, model: "gemma:2b")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.toolsSupported, false)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[1].tools.isEmpty)
    }

    func testTesterReportsFailure() async {
        let client = FakeLLMClient([.failure(LLMError.unauthorized)])
        let result = await AssistantConnectionTester.check(client: client, model: "m")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, LLMError.unauthorized.userMessage)
        XCTAssertNil(result.toolsSupported)
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/LLMClientFactoryTests.swift
scripts/test.sh LLMClientFactoryTests
```
Expected: build error `cannot find 'LLMClientFactory' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/LLMClientFactory.swift`:
```swift
import Foundation

enum LLMClientFactory {
    static func make(
        settings: AssistantSettings,
        apiKey: String,
        transport: HTTPTransport = URLSessionTransport()
    ) throws -> any LLMClient {
        guard let url = normalizedBaseURL(settings.baseURL, provider: settings.provider) else { throw LLMError.invalidURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.provider.requiresAPIKey && key.isEmpty { throw LLMError.missingAPIKey }
        let timeout = TimeInterval(settings.timeoutSeconds)
        switch settings.provider {
        case .ollamaCloud, .ollamaLocal:
            return OllamaClient(baseURL: url, apiKey: settings.provider.usesAPIKey ? key : "", timeout: timeout, transport: transport)
        case .openAICompatible:
            return OpenAICompatibleClient(baseURL: url, apiKey: key, timeout: timeout, transport: transport)
        }
    }

    // Users often paste ".../v1" or ".../api"; the clients append those themselves.
    static func normalizedBaseURL(_ text: String, provider: AssistantProvider) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        let suffix = provider == .openAICompatible ? "/v1" : "/api"
        if value.lowercased().hasSuffix(suffix) { value.removeLast(suffix.count) }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }
}
```

`SpotlessMac/Assistant/AssistantConnectionTester.swift`:
```swift
import Foundation

struct ConnectionCheckResult: Equatable, Sendable {
    let ok: Bool
    let message: String
    let toolsSupported: Bool?

    static func failure(_ error: Error) -> ConnectionCheckResult {
        ConnectionCheckResult(ok: false, message: (error as? LLMError)?.userMessage ?? error.localizedDescription, toolsSupported: nil)
    }
}

enum AssistantConnectionTester {
    static let probeTool = ToolSpec(
        name: "item_details",
        description: "Подробности об элементе по ID",
        parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
    )

    // Sends a real short request: first with a tool, then without if tools are unsupported.
    static func check(client: any LLMClient, model: String) async -> ConnectionCheckResult {
        let messages = [WireMessage(role: .user, content: "Ответь одним словом: готово")]
        do {
            try await drain(client.stream(ChatRequest(model: model, messages: messages, tools: [probeTool])))
            return ConnectionCheckResult(ok: true, message: "Ответила \(model) · инструменты поддерживаются", toolsSupported: true)
        } catch LLMError.toolsUnsupported {
            do {
                try await drain(client.stream(ChatRequest(model: model, messages: messages)))
                return ConnectionCheckResult(ok: true, message: "Ответила \(model) · инструменты не поддерживаются, план будет текстовым", toolsSupported: false)
            } catch {
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    private static func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws {
        for try await _ in stream {}
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/LLMClientFactory.swift SpotlessMac/Assistant/AssistantConnectionTester.swift
scripts/test.sh LLMClientFactoryTests
```
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/LLMClientFactoryTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): client factory and connection check"
```

---

### Task 6: System snapshot model and path redaction

**Files:**
- Create: `SpotlessMac/Assistant/SystemSnapshot.swift`
- Create: `SpotlessMac/Assistant/PathRedactor.swift`
- Create: `SpotlessMacTests/AssistantSnapshotFixtures.swift`
- Create: `SpotlessMacTests/PathRedactorTests.swift`

**Interfaces:**
- Consumes: `ScanCategory`, `CleanupDisposition` (existing models).
- Produces:
  - `extension CleanupDisposition { var code: String }` (`rebuildable|redownload|personalData|inspectOnly`)
  - `struct SnapshotItem: Equatable, Sendable { shortID: String; itemID: UUID; path: String; bytes: Int64; category: ScanCategory; disposition: CleanupDisposition; reason: String; modifiedAt: Date?; owner: String?; var isBatchCleanable: Bool }`
  - `struct CategorySummary { category; bytes; count }`, `struct VolumeInfo { var name; totalBytes; availableBytes; freeFraction }`, `struct DockerKindSummary { kindName; count; bytes; dataLossCount }`, `struct DockerInfo { status; virtualDiskBytes: Int64?; reclaimableBytes: Int64?; kinds }`, `struct LeftoverInfo { appName; count; exactCount; nameOnlyCount; bytes }`, `struct LastCleanupInfo { trashedBytes; observedFreeSpaceDelta: Int64? }` — all `Equatable, Sendable`.
  - `struct SystemSnapshot: Equatable, Sendable { takenAt; volume; fullDiskAccess: Bool?; lastScanAt: Date?; categories; items; docker; leftovers; lastCleanup; hasScan; item(shortID:) }`
  - `struct AssistantFocus: Equatable, Sendable { title: String; path: String; facts: [String] }`
  - `struct PathRedactor: Sendable { init(homePath:); mutating redact(_:) -> String; mutating redactText(_:) -> String; restore(_:) -> String; static personalRoots }`
  - Test fixture: `SystemSnapshot.sample()`, `SystemSnapshot.testHome`, `SystemSnapshot.testDate`.

- [ ] **Step 1: Write fixture and failing tests**

`SpotlessMacTests/AssistantSnapshotFixtures.swift`:
```swift
import Foundation
@testable import SpotlessMac

extension SystemSnapshot {
    static let testHome = "/Users/tester"
    static let testDate = Date(timeIntervalSince1970: 1_790_000_000)

    static func sample() -> SystemSnapshot {
        func item(_ number: Int, _ path: String, _ gigabytes: Double, _ category: ScanCategory,
                  _ disposition: CleanupDisposition, daysOld: Int?) -> SnapshotItem {
            SnapshotItem(
                shortID: "c\(number)", itemID: UUID(), path: testHome + path,
                bytes: Int64(gigabytes * 1_000_000_000), category: category, disposition: disposition,
                reason: category.cleanupReason,
                modifiedAt: daysOld.map { testDate.addingTimeInterval(-Double($0) * 86_400) }, owner: nil
            )
        }
        let items = [
            item(1, "/Library/Developer/Xcode/DerivedData", 9.8, .developerCaches, .rebuildable, daysOld: 50),
            item(2, "/Projects/secret-client/node_modules", 3.2, .projectArtifacts, .rebuildable, daysOld: 90),
            item(3, "/Library/Caches/com.spotify.client", 1.5, .userCaches, .rebuildable, daysOld: 2),
            item(4, "/Documents/Мой проект/recording.m4a", 0.9, .recordings, .personalData, daysOld: 10),
            item(5, "/Library/Logs/DiagnosticReports", 0.4, .logs, .rebuildable, daysOld: 40),
            item(6, "/Downloads/big.iso", 0.3, .largeFiles, .inspectOnly, daysOld: 200),
        ]
        let categories = Dictionary(grouping: items, by: \.category)
            .map { CategorySummary(category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        return SystemSnapshot(
            takenAt: testDate,
            volume: VolumeInfo(name: "Macintosh HD", totalBytes: 494_000_000_000, availableBytes: 31_000_000_000),
            fullDiskAccess: true,
            lastScanAt: testDate.addingTimeInterval(-3_600),
            categories: categories,
            items: items,
            docker: DockerInfo(status: "Docker запущен", virtualDiskBytes: 48_000_000_000, reclaimableBytes: 6_000_000_000,
                               kinds: [DockerKindSummary(kindName: "Неиспользуемые образы", count: 12, bytes: 5_000_000_000, dataLossCount: 0)]),
            leftovers: nil,
            lastCleanup: nil
        )
    }
}
```

`SpotlessMacTests/PathRedactorTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class PathRedactorTests: XCTestCase {
    private func redactor() -> PathRedactor { PathRedactor(homePath: "/Users/tester") }

    func testHomeBecomesTilde() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Library/Caches/x"), "~/Library/Caches/x")
        XCTAssertEqual(r.redact("/Users/tester"), "~")
        XCTAssertEqual(r.redact("/Users/tester/Projects"), "~/Projects")
    }

    func testPersonalFoldersGetStableAliases() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Users/tester/Projects/secret-client/node_modules"), "~/Projects/<папка-1>/node_modules")
        XCTAssertEqual(r.redact("/Users/tester/MyProjects/other/build"), "~/MyProjects/<папка-2>/build")
        XCTAssertEqual(r.redact("/Users/tester/Projects/secret-client/dist"), "~/Projects/<папка-1>/dist")
    }

    // Review focus 3: spaces and Cyrillic.
    func testSpacesAndCyrillicAreRedacted() {
        var r = redactor()
        let redacted = r.redact("/Users/tester/Documents/Мой проект/запись.m4a")
        XCTAssertEqual(redacted, "~/Documents/<папка-1>/запись.m4a")
        XCTAssertFalse(redacted.contains("Мой проект"))
        XCTAssertEqual(r.restore("Удалите <папка-1>"), "Удалите Мой проект")
    }

    func testPathsOutsideHomeAndLookalikesUntouched() {
        var r = redactor()
        XCTAssertEqual(r.redact("/Library/Logs/x"), "/Library/Logs/x")
        XCTAssertEqual(r.redact("/Users/testerX/Projects/a"), "/Users/testerX/Projects/a")
    }

    func testRedactTextReplacesEmbeddedPaths() {
        var r = redactor()
        let text = r.redactText("посмотри /Users/tester/Projects/secret-client/build и /tmp/x")
        XCTAssertEqual(text, "посмотри ~/Projects/<папка-1>/build и /tmp/x")
        XCTAssertEqual(r.redactText("без путей"), "без путей")
    }

    func testRestoreMapsAliasesBack() {
        var r = redactor()
        _ = r.redact("/Users/tester/Projects/a/x")
        _ = r.redact("/Users/tester/Projects/b/x")
        XCTAssertEqual(r.restore("<папка-1> и <папка-2>"), "a и b")
    }

    func testSnapshotHelpers() {
        let snapshot = SystemSnapshot.sample()
        XCTAssertTrue(snapshot.hasScan)
        XCTAssertEqual(snapshot.item(shortID: "c3")?.category, .userCaches)
        XCTAssertNil(snapshot.item(shortID: "c99"))
        XCTAssertEqual(CleanupDisposition.personalData.code, "personalData")
        XCTAssertEqual(snapshot.volume?.freeFraction ?? 0, 31.0 / 494.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantSnapshotFixtures.swift SpotlessMacTests/PathRedactorTests.swift
scripts/test.sh PathRedactorTests
```
Expected: build errors `cannot find type 'SystemSnapshot'`, `'PathRedactor'`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/SystemSnapshot.swift`:
```swift
import Foundation

extension CleanupDisposition {
    var code: String {
        switch self {
        case .rebuildable: "rebuildable"
        case .redownload: "redownload"
        case .personalData: "personalData"
        case .inspectOnly: "inspectOnly"
        }
    }
}

struct SnapshotItem: Equatable, Sendable {
    let shortID: String
    let itemID: UUID
    let path: String
    let bytes: Int64
    let category: ScanCategory
    let disposition: CleanupDisposition
    let reason: String
    let modifiedAt: Date?
    let owner: String?

    var isBatchCleanable: Bool { category.isBatchCleanable }
}

struct CategorySummary: Equatable, Sendable {
    let category: ScanCategory
    let bytes: Int64
    let count: Int
}

struct VolumeInfo: Equatable, Sendable {
    var name: String
    let totalBytes: Int64
    let availableBytes: Int64

    var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
}

struct DockerKindSummary: Equatable, Sendable {
    let kindName: String
    let count: Int
    let bytes: Int64
    let dataLossCount: Int
}

struct DockerInfo: Equatable, Sendable {
    let status: String
    let virtualDiskBytes: Int64?
    let reclaimableBytes: Int64?
    let kinds: [DockerKindSummary]
}

struct LeftoverInfo: Equatable, Sendable {
    let appName: String
    let count: Int
    let exactCount: Int
    let nameOnlyCount: Int
    let bytes: Int64
}

struct LastCleanupInfo: Equatable, Sendable {
    let trashedBytes: Int64
    let observedFreeSpaceDelta: Int64?
}

// Immutable copy of what the assistant may know. Holds no references to live objects.
struct SystemSnapshot: Equatable, Sendable {
    var takenAt: Date
    var volume: VolumeInfo?
    var fullDiskAccess: Bool?
    var lastScanAt: Date?
    var categories: [CategorySummary] = []
    var items: [SnapshotItem] = []
    var docker: DockerInfo?
    var leftovers: LeftoverInfo?
    var lastCleanup: LastCleanupInfo?

    var hasScan: Bool { lastScanAt != nil }

    func item(shortID: String) -> SnapshotItem? {
        items.first { $0.shortID == shortID }
    }
}

struct AssistantFocus: Equatable, Sendable {
    let title: String
    let path: String
    let facts: [String]
}
```

`SpotlessMac/Assistant/PathRedactor.swift`:
```swift
import Foundation

// Cloud-only redaction: the user name becomes "~", the first folder under
// personal roots becomes "<папка-N>". Aliases are stable within a conversation.
struct PathRedactor: Sendable {
    static let personalRoots: Set<String> = [
        "Documents", "Desktop", "Downloads", "Projects", "MyProjects", "Developer",
        "src", "code", "Movies", "Music", "Pictures",
    ]

    let homePath: String
    private var aliasByKey: [String: String] = [:]
    private var nameByAlias: [String: String] = [:]

    init(homePath: String) {
        var home = homePath
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.homePath = home
    }

    mutating func redact(_ path: String) -> String {
        guard path == homePath || path.hasPrefix(homePath + "/") else { return path }
        var components = path.dropFirst(homePath.count).split(separator: "/").map(String.init)
        if components.count >= 2, Self.personalRoots.contains(components[0]) {
            let key = components[0] + "/" + components[1]
            let alias: String
            if let existing = aliasByKey[key] {
                alias = existing
            } else {
                alias = "<папка-\(aliasByKey.count + 1)>"
                aliasByKey[key] = alias
                nameByAlias[alias] = components[1]
            }
            components[1] = alias
        }
        return (["~"] + components).joined(separator: "/")
    }

    // Redacts home-based paths embedded in free text (user messages, history).
    mutating func redactText(_ text: String) -> String {
        guard text.contains(homePath) else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: homePath) + #"(?![^/\s])(?:/[^\s|`'"«»,;()]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: redact(String(result[range])))
        }
        return result
    }

    func restore(_ text: String) -> String {
        nameByAlias.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/SystemSnapshot.swift SpotlessMac/Assistant/PathRedactor.swift
scripts/test.sh PathRedactorTests
```
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/AssistantSnapshotFixtures.swift SpotlessMacTests/PathRedactorTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): system snapshot model and path redaction"
```

---

### Task 7: Snapshot renderer and system prompt

**Files:**
- Create: `SpotlessMac/Assistant/SnapshotRenderer.swift`
- Create: `SpotlessMac/Assistant/AssistantPrompt.swift`
- Create: `SpotlessMacTests/SnapshotRendererTests.swift`

**Interfaces:**
- Consumes: Task 6 snapshot types.
- Produces:
  - `enum SnapshotRenderer { static maxItems = 150; static maxCharacters = 32_000; render(_:formatPath:) -> String; itemLine(_:formatPath:) -> String; itemCard(_:formatPath:) -> String; bytes(_:) -> String; date(_:) -> String; dateTime(_:) -> String; percent(_:) -> String }`
  - `enum AssistantPrompt { static func system(toolsEnabled: Bool) -> String }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/SnapshotRendererTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class SnapshotRendererTests: XCTestCase {
    func testRendersDiskCategoriesAndItems() {
        let text = SnapshotRenderer.render(.sample()) { $0 }
        XCTAssertTrue(text.contains("«Macintosh HD»"))
        XCTAssertTrue(text.contains("свободно"))
        XCTAssertTrue(text.contains("Полный доступ к диску: есть"))
        XCTAssertTrue(text.contains("developer_caches"))
        XCTAssertTrue(text.contains("c1 | /Users/tester/Library/Developer/Xcode/DerivedData |"))
        XCTAssertTrue(text.contains("| rebuildable |"))
        XCTAssertTrue(text.contains("Docker"))
    }

    func testFormatPathIsAppliedToEveryPath() {
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let text = SnapshotRenderer.render(.sample()) { redactor.redact($0) }
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertFalse(text.contains("secret-client"))
        XCTAssertTrue(text.contains("~/Projects/<папка-1>/node_modules"))
    }

    func testNoScanMessage() {
        let snapshot = SystemSnapshot(takenAt: SystemSnapshot.testDate)
        let text = SnapshotRenderer.render(snapshot) { $0 }
        XCTAssertTrue(text.contains("ещё не проводилось"))
        XCTAssertTrue(text.contains("данные о томе недоступны"))
    }

    // Review focus 2: huge scans stay within budget.
    func testLargeSnapshotStaysWithinBudget() {
        var snapshot = SystemSnapshot.sample()
        snapshot.items = (1...5_000).map { n in
            SnapshotItem(shortID: "c\(n)", itemID: UUID(), path: "/Users/tester/Library/Caches/" + String(repeating: "x", count: 180) + "\(n)",
                         bytes: Int64(10_000 - n), category: .userCaches, disposition: .rebuildable, reason: "r", modifiedAt: nil, owner: nil)
        }
        let text = SnapshotRenderer.render(snapshot) { $0 }
        XCTAssertLessThanOrEqual(text.count, SnapshotRenderer.maxCharacters)
        XCTAssertTrue(text.contains("из 5000"))
        XCTAssertTrue(text.contains("list_items"))
    }

    func testItemCard() {
        let item = SystemSnapshot.sample().items[3]
        let card = SnapshotRenderer.itemCard(item) { $0 }
        XCTAssertTrue(card.contains("ID: c4"))
        XCTAssertTrue(card.contains("Политика: personalData"))
        XCTAssertTrue(card.contains("Пакетная очистка: нет"))
    }

    func testPromptVariants() {
        let fallback = AssistantPrompt.system(toolsEnabled: false)
        XCTAssertTrue(fallback.contains("```spotless-plan"))
        XCTAssertTrue(fallback.contains("не можешь ничего удалить"))
        let tools = AssistantPrompt.system(toolsEnabled: true)
        XCTAssertTrue(tools.contains("propose_plan"))
        XCTAssertFalse(tools.contains("```spotless-plan"))
        for category in ScanCategory.allCases {
            XCTAssertTrue(tools.contains(category.rawValue), category.rawValue)
        }
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/SnapshotRendererTests.swift
scripts/test.sh SnapshotRendererTests
```
Expected: build error `cannot find 'SnapshotRenderer' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/SnapshotRenderer.swift`:
```swift
import Foundation

enum SnapshotRenderer {
    static let maxItems = 150
    static let maxCharacters = 32_000 // ≈ 8k tokens at ~4 chars/token
    private static let tailReserve = 2_000

    static func render(_ snapshot: SystemSnapshot, formatPath: (String) -> String) -> String {
        var lines = ["Снимок системы на \(dateTime(snapshot.takenAt))."]
        if let volume = snapshot.volume {
            lines.append("Диск: «\(volume.name)», всего \(bytes(volume.totalBytes)), свободно \(bytes(volume.availableBytes)) (\(percent(volume.freeFraction))).")
        } else {
            lines.append("Диск: данные о томе недоступны.")
        }
        let fda = snapshot.fullDiskAccess.map { $0 ? "есть" : "нет" } ?? "неизвестно"
        lines.append("Полный доступ к диску: \(fda).")

        if let scanDate = snapshot.lastScanAt {
            let total = snapshot.items.reduce(Int64(0)) { $0 + $1.bytes }
            lines.append("Сканирование: \(dateTime(scanDate)), найдено \(snapshot.items.count) элементов на \(bytes(total)).")
            if !snapshot.categories.isEmpty {
                lines.append("Категории (id | название | объём | элементов | пакетная очистка):")
                for summary in snapshot.categories {
                    let batch = summary.category.isBatchCleanable ? "да" : "нет, только вручную"
                    lines.append("- \(summary.category.rawValue) | \(summary.category.displayName) | \(bytes(summary.bytes)) | \(summary.count) | \(batch)")
                }
            }
            if !snapshot.items.isEmpty {
                lines.append("Крупные элементы (ID | путь | размер | категория | политика | изменён | владелец):")
                var used = lines.reduce(0) { $0 + $1.count + 1 }
                var shown = 0
                for item in snapshot.items.prefix(maxItems) {
                    let line = itemLine(item, formatPath: formatPath)
                    guard used + line.count + 1 <= maxCharacters - tailReserve else { break }
                    lines.append(line)
                    used += line.count + 1
                    shown += 1
                }
                if shown < snapshot.items.count {
                    lines.append("(показано \(shown) из \(snapshot.items.count); остальные доступны через list_items или по просьбе пользователя)")
                }
            }
        } else {
            lines.append("Сканирование: ещё не проводилось. Предложи пользователю нажать «Запустить сканирование».")
        }

        if let docker = snapshot.docker {
            let disk = docker.virtualDiskBytes.map(bytes) ?? "неизвестно"
            let reclaimable = docker.reclaimableBytes.map(bytes) ?? "неизвестно"
            lines.append("Docker: \(docker.status); виртуальный диск \(disk), можно освободить \(reclaimable).")
            for kind in docker.kinds {
                let risk = kind.dataLossCount > 0 ? ", с риском потери данных: \(kind.dataLossCount)" : ""
                lines.append("- \(kind.kindName): \(kind.count) шт., \(bytes(kind.bytes))\(risk)")
            }
        } else {
            lines.append("Docker: данные не загружены (вкладка Docker ещё не открывалась).")
        }

        if let leftovers = snapshot.leftovers {
            lines.append("Остатки программы «\(leftovers.appName)»: \(leftovers.count) элементов (точное совпадение: \(leftovers.exactCount), только по имени: \(leftovers.nameOnlyCount)), \(bytes(leftovers.bytes)).")
        }
        if let cleanup = snapshot.lastCleanup {
            let delta = cleanup.observedFreeSpaceDelta.map(bytes) ?? "не измерен"
            lines.append("Последняя очистка: в Корзину перемещено \(bytes(cleanup.trashedBytes)), наблюдаемый прирост свободного места \(delta).")
        }
        return lines.joined(separator: "\n")
    }

    static func itemLine(_ item: SnapshotItem, formatPath: (String) -> String) -> String {
        [item.shortID, formatPath(item.path), bytes(item.bytes), item.category.rawValue, item.disposition.code,
         item.modifiedAt.map(date) ?? "—", item.owner ?? "—"].joined(separator: " | ")
    }

    static func itemCard(_ item: SnapshotItem, formatPath: (String) -> String) -> String {
        [
            "ID: \(item.shortID)",
            "Путь: \(formatPath(item.path))",
            "Размер: \(bytes(item.bytes))",
            "Категория: \(item.category.rawValue) (\(item.category.displayName))",
            "Политика: \(item.disposition.code) — \(item.disposition.label)",
            "Причина: \(item.reason)",
            "Изменён: \(item.modifiedAt.map(date) ?? "неизвестно")",
            "Владелец: \(item.owner ?? "—")",
            "Пакетная очистка: \(item.isBatchCleanable ? "да" : "нет, удаляется вручную")",
        ].joined(separator: "\n")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ value: Date) -> String { format(value, "yyyy-MM-dd") }
    static func dateTime(_ value: Date) -> String { format(value, "yyyy-MM-dd HH:mm") }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private static func format(_ value: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: value)
    }
}
```

`SpotlessMac/Assistant/AssistantPrompt.swift`:
```swift
import Foundation

enum AssistantPrompt {
    static func system(toolsEnabled: Bool) -> String {
        [base, glossary, toolsEnabled ? toolsGuide : fallbackPlanGuide].joined(separator: "\n\n")
    }

    static let base = """
    Ты — помощник по уходу за Mac внутри приложения SpotlessMac. Отвечай по-русски, кратко и по делу.
    Правила:
    - Ты не можешь ничего удалить и не можешь запускать команды. Ты только объясняешь и предлагаешь план; удаление выполняет сам пользователь в окне «Освободить место» после проверки списка.
    - Всё, что пользователь удаляет через SpotlessMac, перемещается в Корзину и может быть восстановлено.
    - Никогда не советуй удалять /System, файл подкачки (/private/var/vm), личные данные (политика personalData) и элементы «только просмотр» (inspectOnly).
    - Опирайся только на снимок системы и результаты инструментов. Если элемента нет в данных — скажи «не знаю», не придумывай пути и размеры.
    - Пути вида <папка-N> — обезличенные папки пользователя; используй их как есть.
    Ответ о конкретном элементе: сначала вердикт («безопасно», «осторожно» или «не трогать»), затем что это и что произойдёт после удаления (что пересоздастся, что придётся скачать заново, что потеряется).
    Предлагай план очистки, только если пользователь просит освободить место или это явно полезно.
    """

    static var glossary: String {
        var lines = [
            "Политики:",
            "- rebuildable — создаётся заново автоматически.",
            "- redownload — потребуется повторная загрузка.",
            "- personalData — личные данные, не предлагай к удалению.",
            "- inspectOnly — только просмотр, удалять нельзя.",
            "Категории (id — название: пояснение):",
        ]
        for category in ScanCategory.allCases {
            let manual = category.isBatchCleanable ? "" : " Удаляется только вручную по одному."
            lines.append("- \(category.rawValue) — \(category.displayName): \(category.cleanupReason)\(manual)")
        }
        return lines.joined(separator: "\n")
    }

    static let toolsGuide = """
    Инструменты: list_items — найти элементы по категории, размеру и возрасту; item_details — подробности по ID; propose_plan — предложить план очистки (ID элементов и/или фильтры по категории). Инструментов удаления нет. Вызывай propose_plan не больше одного раза за ответ и после него кратко объясни план словами.
    """

    static let fallbackPlanGuide = """
    Чтобы предложить план очистки, добавь в самый конец ответа ровно один блок:
    ```spotless-plan
    {"items": ["c12", "c40"], "filters": [{"category": "developer_caches", "olderThanDays": 30}], "reason": "кратко, почему это безопасно"}
    ```
    items — ID из снимка; filters — категория (обязательна) и необязательные olderThanDays и minBytes. Не добавляй блок, если план не нужен.
    """
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/SnapshotRenderer.swift SpotlessMac/Assistant/AssistantPrompt.swift
scripts/test.sh SnapshotRendererTests
```
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/SnapshotRendererTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): snapshot renderer and system prompt"
```

---

### Task 8: Plan proposal, parser and resolver

**Files:**
- Create: `SpotlessMac/Assistant/AssistantPlan.swift`
- Create: `SpotlessMac/Assistant/PlanParser.swift`
- Create: `SpotlessMacTests/AssistantPlanTests.swift`

**Interfaces:**
- Consumes: `SystemSnapshot`, `SnapshotItem` (Task 6), `SnapshotRenderer.bytes` (Task 7).
- Produces:
  - `struct PlanFilter: Codable, Equatable, Sendable { category: String?; olderThanDays: Int?; minBytes: Int64? }`
  - `struct PlanProposal: Codable, Equatable, Sendable { items: [String]; filters: [PlanFilter]; reason: String; init(items:filters:reason:); static func decode(json:) -> PlanProposal? }`
  - `struct SkippedGroup: Codable, Equatable, Sendable { label; count }`
  - `struct AssistantPlan: Codable, Equatable, Sendable { itemIDs: [UUID]; totalBytes: Int64; reason: String; skipped: [SkippedGroup]; manualReview: [String]; isEmpty; isMeaningful }`
  - `enum PlanResolver { static func resolve(_:in:) -> AssistantPlan }`
  - `enum PlanParser { struct Extraction: Equatable { text; proposal; malformed }; static func extract(from:) -> Extraction; static func visibleWhileStreaming(_:) -> String }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/AssistantPlanTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class AssistantPlanTests: XCTestCase {
    private let snapshot = SystemSnapshot.sample()
    private func id(_ shortID: String) -> UUID { snapshot.item(shortID: shortID)!.itemID }

    func testResolvesIDsAndCountsUnknown() {
        let plan = PlanResolver.resolve(PlanProposal(items: ["c1", "c3", "c99", "c1"], reason: " кеши "), in: snapshot)
        XCTAssertEqual(plan.itemIDs, [id("c1"), id("c3")])
        XCTAssertEqual(plan.totalBytes, 9_800_000_000 + 1_500_000_000)
        XCTAssertEqual(plan.reason, "кеши")
        XCTAssertEqual(plan.skipped, [SkippedGroup(label: "неизвестные ID", count: 1)])
    }

    func testSkipsPersonalInspectOnlyAndListsManualItems() {
        let plan = PlanResolver.resolve(PlanProposal(items: ["c2", "c4", "c6"]), in: snapshot)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.isMeaningful)
        XCTAssertEqual(plan.skipped, [
            SkippedGroup(label: "личные данные", count: 1),
            SkippedGroup(label: "только просмотр", count: 1),
            SkippedGroup(label: "удаляются вручную по одному", count: 1),
        ])
        XCTAssertEqual(plan.manualReview.count, 1)
        XCTAssertTrue(plan.manualReview[0].hasPrefix("node_modules"))
    }

    func testFiltersByCategoryAgeAndSize() {
        let older = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "developer_caches", olderThanDays: 30)]), in: snapshot)
        XCTAssertEqual(older.itemIDs, [id("c1")])
        let recent = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "user_caches", olderThanDays: 30)]), in: snapshot)
        XCTAssertTrue(recent.itemIDs.isEmpty)
        let big = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(category: "logs", minBytes: 1_000_000_000)]), in: snapshot)
        XCTAssertTrue(big.itemIDs.isEmpty)
    }

    func testFilterWithoutCategoryMatchesNothing() {
        let plan = PlanResolver.resolve(PlanProposal(filters: [PlanFilter(olderThanDays: 1)]), in: snapshot)
        XCTAssertTrue(plan.itemIDs.isEmpty)
        XCTAssertFalse(plan.isMeaningful)
    }

    func testProposalDecodingIsLenient() {
        XCTAssertEqual(PlanProposal.decode(json: #"{"items":["c1"]}"#), PlanProposal(items: ["c1"]))
        XCTAssertNil(PlanProposal.decode(json: "nope"))
    }

    func testParserExtractsAndStripsBlock() {
        let text = "Можно почистить кеши.\n\n```spotless-plan\n{\"items\":[\"c1\"],\"reason\":\"r\"}\n```\n"
        let result = PlanParser.extract(from: text)
        XCTAssertEqual(result.text, "Можно почистить кеши.")
        XCTAssertEqual(result.proposal, PlanProposal(items: ["c1"], reason: "r"))
        XCTAssertFalse(result.malformed)
    }

    func testParserFlagsMalformedBlock() {
        let result = PlanParser.extract(from: "Текст\n```spotless-plan\n{broken\n```")
        XCTAssertEqual(result.text, "Текст")
        XCTAssertNil(result.proposal)
        XCTAssertTrue(result.malformed)
    }

    func testParserWithoutBlockAndUnclosedBlock() {
        XCTAssertEqual(PlanParser.extract(from: "просто текст"), .init(text: "просто текст", proposal: nil, malformed: false))
        let unclosed = PlanParser.extract(from: "A\n```spotless-plan\n{\"items\":[\"c3\"]}")
        XCTAssertEqual(unclosed.proposal, PlanProposal(items: ["c3"]))
        XCTAssertEqual(unclosed.text, "A")
    }

    func testVisibleWhileStreamingHidesPartialBlock() {
        XCTAssertEqual(PlanParser.visibleWhileStreaming("Ответ\n```spotless-plan\n{\"ite"), "Ответ")
        XCTAssertEqual(PlanParser.visibleWhileStreaming("Ответ"), "Ответ")
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantPlanTests.swift
scripts/test.sh AssistantPlanTests
```
Expected: build error `cannot find 'PlanResolver' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/AssistantPlan.swift`:
```swift
import Foundation

struct PlanFilter: Codable, Equatable, Sendable {
    var category: String?
    var olderThanDays: Int?
    var minBytes: Int64?
}

struct PlanProposal: Codable, Equatable, Sendable {
    var items: [String]
    var filters: [PlanFilter]
    var reason: String

    init(items: [String] = [], filters: [PlanFilter] = [], reason: String = "") {
        self.items = items
        self.filters = filters
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([String].self, forKey: .items) ?? []
        filters = try container.decodeIfPresent([PlanFilter].self, forKey: .filters) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    static func decode(json: String) -> PlanProposal? {
        try? JSONDecoder().decode(PlanProposal.self, from: Data(json.utf8))
    }
}

struct SkippedGroup: Codable, Equatable, Sendable {
    let label: String
    let count: Int
}

struct AssistantPlan: Codable, Equatable, Sendable {
    let itemIDs: [UUID]
    let totalBytes: Int64
    let reason: String
    let skipped: [SkippedGroup]
    let manualReview: [String]

    var isEmpty: Bool { itemIDs.isEmpty }
    var isMeaningful: Bool { !itemIDs.isEmpty || !skipped.isEmpty || !manualReview.isEmpty }
}

// Turns a model proposal into a selection of existing snapshot items.
// Only batch-cleanable, deletable, non-personal items are ever selected.
enum PlanResolver {
    static let maxManualReviewLines = 10

    static func resolve(_ proposal: PlanProposal, in snapshot: SystemSnapshot) -> AssistantPlan {
        var candidates: [SnapshotItem] = []
        var seen: Set<String> = []
        var unknown = 0

        for shortID in proposal.items {
            guard let item = snapshot.item(shortID: shortID) else { unknown += 1; continue }
            if seen.insert(item.shortID).inserted { candidates.append(item) }
        }
        for filter in proposal.filters {
            guard let raw = filter.category, let category = ScanCategory(rawValue: raw) else { continue }
            let cutoff = filter.olderThanDays.map { snapshot.takenAt.addingTimeInterval(-Double($0) * 86_400) }
            for item in snapshot.items where item.category == category {
                if let minBytes = filter.minBytes, item.bytes < minBytes { continue }
                if let cutoff {
                    guard let modified = item.modifiedAt, modified < cutoff else { continue }
                }
                if seen.insert(item.shortID).inserted { candidates.append(item) }
            }
        }

        var selected: [SnapshotItem] = []
        var manual: [SnapshotItem] = []
        var personal = 0
        var inspectOnly = 0
        for item in candidates {
            switch item.disposition {
            case .personalData: personal += 1
            case .inspectOnly: inspectOnly += 1
            case .rebuildable, .redownload:
                if item.isBatchCleanable { selected.append(item) } else { manual.append(item) }
            }
        }

        var skipped: [SkippedGroup] = []
        if unknown > 0 { skipped.append(SkippedGroup(label: "неизвестные ID", count: unknown)) }
        if personal > 0 { skipped.append(SkippedGroup(label: "личные данные", count: personal)) }
        if inspectOnly > 0 { skipped.append(SkippedGroup(label: "только просмотр", count: inspectOnly)) }
        if !manual.isEmpty { skipped.append(SkippedGroup(label: "удаляются вручную по одному", count: manual.count)) }

        return AssistantPlan(
            itemIDs: selected.map(\.itemID),
            totalBytes: selected.reduce(0) { $0 + $1.bytes },
            reason: proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            skipped: skipped,
            manualReview: manual.prefix(maxManualReviewLines).map {
                "\(URL(filePath: $0.path).lastPathComponent) · \(SnapshotRenderer.bytes($0.bytes))"
            }
        )
    }
}
```

`SpotlessMac/Assistant/PlanParser.swift`:
```swift
import Foundation

// Fallback for models without tool calling: a fenced ```spotless-plan JSON block.
enum PlanParser {
    static let fence = "```spotless-plan"

    struct Extraction: Equatable {
        let text: String
        let proposal: PlanProposal?
        let malformed: Bool
    }

    static func extract(from text: String) -> Extraction {
        guard let regex = try? NSRegularExpression(pattern: "```spotless-plan[ \\t]*\\n?([\\s\\S]*?)(?:```|$)") else {
            return Extraction(text: text, proposal: nil, malformed: false)
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return Extraction(text: text, proposal: nil, malformed: false) }

        var proposal: PlanProposal?
        var sawMalformed = false
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if let decoded = PlanProposal.decode(json: String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)) {
                proposal = proposal ?? decoded
            } else {
                sawMalformed = true
            }
        }
        let cleaned = regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(text: cleaned, proposal: proposal, malformed: proposal == nil && sawMalformed)
    }

    static func visibleWhileStreaming(_ text: String) -> String {
        guard let range = text.range(of: fence) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantPlan.swift SpotlessMac/Assistant/PlanParser.swift
scripts/test.sh AssistantPlanTests
```
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/AssistantPlanTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): plan parser and resolver"
```

---

### Task 9: Closed tool set and toolbox

**Files:**
- Create: `SpotlessMac/Assistant/AssistantTool.swift`
- Create: `SpotlessMac/Assistant/AssistantToolbox.swift`
- Create: `SpotlessMacTests/AssistantToolboxTests.swift`

**Interfaces:**
- Consumes: `ToolCall`, `ToolSpec`, `JSONText` (Task 2); snapshot (Task 6); `SnapshotRenderer` (Task 7); `PlanProposal`, `PlanResolver` (Task 8).
- Produces:
  - `enum ToolParseError: Error, Equatable { unknownTool(String), invalidArguments(String) }`
  - `enum AssistantTool: Equatable, Sendable { listItems(category:minBytes:olderThanDays:limit:), itemDetails(id:), proposePlan(PlanProposal); static names: [String]; static specs: [ToolSpec]; static func parse(_ call: ToolCall) -> Result<AssistantTool, ToolParseError> }`
  - `struct ToolOutcome: Equatable, Sendable { resultText: String; proposal: PlanProposal? }`
  - `enum AssistantToolbox { static func execute(_ call: ToolCall, snapshot: SystemSnapshot, formatPath: (String) -> String) -> ToolOutcome }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/AssistantToolboxTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class AssistantToolboxTests: XCTestCase {
    private let snapshot = SystemSnapshot.sample()

    private func run(_ name: String, _ arguments: String) -> ToolOutcome {
        AssistantToolbox.execute(ToolCall(id: "1", name: name, argumentsJSON: arguments), snapshot: snapshot) { $0 }
    }

    func testToolSetIsExactlyThreeReadOnlyTools() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan"])
        XCTAssertEqual(AssistantTool.specs.map(\.name), AssistantTool.names)
    }

    func testUnknownToolIsRefused() {
        let outcome = run("delete_file", #"{"path":"/Users/tester"}"#)
        XCTAssertTrue(outcome.resultText.contains("не существует"))
        XCTAssertTrue(outcome.resultText.contains("Удалять файлы"))
        XCTAssertNil(outcome.proposal)
        XCTAssertEqual(AssistantTool.parse(ToolCall(id: "1", name: "run_shell", argumentsJSON: "{}")), .failure(.unknownTool("run_shell")))
    }

    func testListItemsFiltersByCategory() {
        let outcome = run("list_items", #"{"category":"logs"}"#)
        XCTAssertTrue(outcome.resultText.contains("c5 |"))
        XCTAssertFalse(outcome.resultText.contains("c1 |"))
    }

    func testListItemsByAgeAndLimit() {
        let old = run("list_items", #"{"olderThanDays":60}"#)
        XCTAssertTrue(old.resultText.contains("c2 |"))
        XCTAssertTrue(old.resultText.contains("c6 |"))
        XCTAssertFalse(old.resultText.contains("c1 |"))
        let limited = run("list_items", #"{"limit":1}"#)
        XCTAssertTrue(limited.resultText.contains("показано 1"))
    }

    func testListItemsRejectsUnknownCategory() {
        XCTAssertTrue(run("list_items", #"{"category":"system"}"#).resultText.contains("Ошибка"))
    }

    func testItemDetails() {
        XCTAssertTrue(run("item_details", #"{"id":"c1"}"#).resultText.contains("Политика: rebuildable"))
        XCTAssertTrue(run("item_details", #"{"id":"c42"}"#).resultText.contains("не найден"))
        XCTAssertTrue(run("item_details", "[]").resultText.contains("Ошибка"))
    }

    func testProposePlanReturnsProposalAndDeletesNothing() {
        let outcome = run("propose_plan", #"{"items":["c1","c3"],"reason":"кеши"}"#)
        XCTAssertEqual(outcome.proposal, PlanProposal(items: ["c1", "c3"], reason: "кеши"))
        XCTAssertTrue(outcome.resultText.contains("Ничего не удалено"))
        XCTAssertTrue(outcome.resultText.contains("2 элементов"))
    }

    func testFormatPathIsUsed() {
        var redactor = PathRedactor(homePath: SystemSnapshot.testHome)
        let outcome = AssistantToolbox.execute(ToolCall(id: "1", name: "list_items", argumentsJSON: "{}"), snapshot: snapshot) { redactor.redact($0) }
        XCTAssertFalse(outcome.resultText.contains("/Users/tester"))
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantToolboxTests.swift
scripts/test.sh AssistantToolboxTests
```
Expected: build error `cannot find 'AssistantToolbox' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/AssistantTool.swift`:
```swift
import Foundation

enum ToolParseError: Error, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
}

// The complete set of tools the model may call. All of them read the
// in-memory snapshot only; there is intentionally no tool that changes anything.
enum AssistantTool: Equatable, Sendable {
    case listItems(category: ScanCategory?, minBytes: Int64?, olderThanDays: Int?, limit: Int)
    case itemDetails(id: String)
    case proposePlan(PlanProposal)

    static let names = ["list_items", "item_details", "propose_plan"]

    static let specs: [ToolSpec] = {
        let categories = ScanCategory.allCases.map(\.rawValue)
        let listItems: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": categories, "description": "Категория из снимка"],
                "minBytes": ["type": "integer", "description": "Минимальный размер в байтах"],
                "olderThanDays": ["type": "integer", "description": "Не изменялся дольше N дней"],
                "limit": ["type": "integer", "description": "Сколько вернуть, 1–200, по умолчанию 50"],
            ],
        ]
        let itemDetails: [String: Any] = [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "ID элемента, например c12"]],
            "required": ["id"],
        ]
        let proposePlan: [String: Any] = [
            "type": "object",
            "properties": [
                "items": ["type": "array", "items": ["type": "string"], "description": "ID элементов из снимка"],
                "filters": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "category": ["type": "string", "enum": categories],
                            "olderThanDays": ["type": "integer"],
                            "minBytes": ["type": "integer"],
                        ],
                        "required": ["category"],
                    ],
                ],
                "reason": ["type": "string", "description": "Кратко, почему это безопасно"],
            ],
            "required": ["reason"],
        ]
        return [
            ToolSpec(name: "list_items", description: "Найти найденные сканированием элементы по категории, размеру и возрасту.", parametersJSON: JSONText.string(from: listItems)),
            ToolSpec(name: "item_details", description: "Подробности об элементе снимка по его ID.", parametersJSON: JSONText.string(from: itemDetails)),
            ToolSpec(name: "propose_plan", description: "Предложить пользователю план очистки. Ничего не удаляет: пользователь сам проверит список.", parametersJSON: JSONText.string(from: proposePlan)),
        ]
    }()

    static func parse(_ call: ToolCall) -> Result<AssistantTool, ToolParseError> {
        guard names.contains(call.name) else { return .failure(.unknownTool(call.name)) }
        guard let arguments = JSONText.object(from: call.argumentsJSON) as? [String: Any] else {
            return .failure(.invalidArguments("аргументы должны быть JSON-объектом"))
        }
        switch call.name {
        case "list_items":
            var category: ScanCategory?
            if let raw = arguments["category"] as? String {
                guard let parsed = ScanCategory(rawValue: raw) else { return .failure(.invalidArguments("неизвестная категория \(raw)")) }
                category = parsed
            }
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), 200)
            return .success(.listItems(
                category: category,
                minBytes: (arguments["minBytes"] as? NSNumber)?.int64Value,
                olderThanDays: (arguments["olderThanDays"] as? NSNumber)?.intValue,
                limit: limit
            ))
        case "item_details":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.invalidArguments("нужен id")) }
            return .success(.itemDetails(id: id))
        default:
            guard let proposal = PlanProposal.decode(json: call.argumentsJSON) else {
                return .failure(.invalidArguments("неверный формат плана"))
            }
            return .success(.proposePlan(proposal))
        }
    }
}
```

`SpotlessMac/Assistant/AssistantToolbox.swift`:
```swift
import Foundation
import os

struct ToolOutcome: Equatable, Sendable {
    let resultText: String
    let proposal: PlanProposal?
}

enum AssistantToolbox {
    private static let logger = Logger(subsystem: "com.spotlessmac.app", category: "assistant")

    static func execute(_ call: ToolCall, snapshot: SystemSnapshot, formatPath: (String) -> String) -> ToolOutcome {
        switch AssistantTool.parse(call) {
        case .failure(.unknownTool(let name)):
            logger.warning("Assistant requested unknown tool \(name, privacy: .public)")
            return ToolOutcome(
                resultText: "Ошибка: инструмента «\(name)» не существует. Доступны только list_items, item_details и propose_plan. Удалять файлы, запускать команды и менять систему ассистент не может.",
                proposal: nil
            )
        case .failure(.invalidArguments(let reason)):
            return ToolOutcome(resultText: "Ошибка в аргументах \(call.name): \(reason).", proposal: nil)
        case .success(.listItems(let category, let minBytes, let olderThanDays, let limit)):
            let cutoff = olderThanDays.map { snapshot.takenAt.addingTimeInterval(-Double($0) * 86_400) }
            let matches = snapshot.items.filter { item in
                if let category, item.category != category { return false }
                if let minBytes, item.bytes < minBytes { return false }
                if let cutoff {
                    guard let modified = item.modifiedAt, modified < cutoff else { return false }
                }
                return true
            }
            guard !matches.isEmpty else { return ToolOutcome(resultText: "Ничего не найдено.", proposal: nil) }
            let shown = matches.prefix(limit)
            let header = "Найдено \(matches.count), показано \(shown.count) (ID | путь | размер | категория | политика | изменён | владелец):"
            let lines = shown.map { SnapshotRenderer.itemLine($0, formatPath: formatPath) }
            return ToolOutcome(resultText: ([header] + lines).joined(separator: "\n"), proposal: nil)
        case .success(.itemDetails(let id)):
            guard let item = snapshot.item(shortID: id) else {
                return ToolOutcome(resultText: "Элемент \(id) не найден в снимке.", proposal: nil)
            }
            return ToolOutcome(resultText: SnapshotRenderer.itemCard(item, formatPath: formatPath), proposal: nil)
        case .success(.proposePlan(let proposal)):
            let plan = PlanResolver.resolve(proposal, in: snapshot)
            return ToolOutcome(
                resultText: "План показан пользователю карточкой: \(plan.itemIDs.count) элементов, \(SnapshotRenderer.bytes(plan.totalBytes)). Ничего не удалено — пользователь сам проверит список и решит. Кратко объясни план словами.",
                proposal: proposal
            )
        }
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantTool.swift SpotlessMac/Assistant/AssistantToolbox.swift
scripts/test.sh AssistantToolboxTests
```
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/AssistantToolboxTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): closed read-only tool set"
```

---

### Task 10: Conversation messages and store

**Files:**
- Create: `SpotlessMac/Assistant/AssistantMessage.swift`
- Create: `SpotlessMac/Assistant/ConversationStore.swift`
- Create: `SpotlessMacTests/ConversationStoreTests.swift`

**Interfaces:**
- Consumes: `AssistantPlan` (Task 8).
- Produces:
  - `struct AssistantMessage: Codable, Equatable, Identifiable, Sendable { enum Role { user, assistant }; enum Status { streaming, complete, stopped, interrupted, failed }; id; role; text; status; plan: AssistantPlan?; planDismissed; planMalformed; errorText: String?; errorOpensSettings; model: String?; createdAt; static func user(_:at:) }`
  - `struct ConversationStore: Sendable { fileURL: URL; static maxStoredMessages = 200; static func defaultFileURL() -> URL; load() -> [AssistantMessage]; save(_:) }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/ConversationStoreTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class ConversationStoreTests: XCTestCase {
    private var store: ConversationStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory.appending(path: "assistant-\(UUID().uuidString)")
        store = ConversationStore(fileURL: dir.appending(path: "conversation.json"))
    }

    func testRoundTripIncludingPlan() {
        var answer = AssistantMessage(id: UUID(), role: .assistant, text: "ответ", status: .complete, model: "m", createdAt: Date(timeIntervalSince1970: 100))
        answer.plan = AssistantPlan(itemIDs: [UUID()], totalBytes: 5, reason: "r", skipped: [SkippedGroup(label: "l", count: 1)], manualReview: ["x"])
        let messages = [AssistantMessage.user("вопрос", at: Date(timeIntervalSince1970: 99)), answer]
        store.save(messages)
        XCTAssertEqual(store.load(), messages)
    }

    func testMissingAndCorruptFilesLoadEmpty() throws {
        XCTAssertEqual(store.load(), [])
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
    }

    func testStreamingMessagesLoadAsInterrupted() {
        store.save([AssistantMessage(id: UUID(), role: .assistant, text: "полу", status: .streaming, createdAt: Date())])
        XCTAssertEqual(store.load().first?.status, .interrupted)
    }

    func testKeepsOnlyLatestMessages() {
        let many = (0..<250).map { AssistantMessage.user("m\($0)", at: Date(timeIntervalSince1970: Double($0))) }
        store.save(many)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, ConversationStore.maxStoredMessages)
        XCTAssertEqual(loaded.first?.text, "m50")
    }

    func testDefaultLocation() {
        XCTAssertTrue(ConversationStore.defaultFileURL().path.hasSuffix("Application Support/SpotlessMac/assistant-conversation.json"))
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/ConversationStoreTests.swift
scripts/test.sh ConversationStoreTests
```
Expected: build error `cannot find 'ConversationStore' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/AssistantMessage.swift`:
```swift
import Foundation

struct AssistantMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable { case streaming, complete, stopped, interrupted, failed }

    let id: UUID
    let role: Role
    var text: String
    var status: Status
    var plan: AssistantPlan?
    var planDismissed = false
    var planMalformed = false
    var errorText: String?
    var errorOpensSettings = false
    var model: String?
    let createdAt: Date

    static func user(_ text: String, at date: Date) -> AssistantMessage {
        AssistantMessage(id: UUID(), role: .user, text: text, status: .complete, createdAt: date)
    }
}
```

`SpotlessMac/Assistant/ConversationStore.swift`:
```swift
import Foundation

// Persists only the last conversation, as JSON, in the app's own support folder.
struct ConversationStore: Sendable {
    static let maxStoredMessages = 200

    let fileURL: URL

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "SpotlessMac", directoryHint: .isDirectory)
            .appending(path: "assistant-conversation.json")
    }

    func load() -> [AssistantMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let messages = try? JSONDecoder().decode([AssistantMessage].self, from: data) else { return [] }
        return messages.map { message in
            var copy = message
            if copy.status == .streaming { copy.status = .interrupted }
            return copy
        }
    }

    func save(_ messages: [AssistantMessage]) {
        guard let data = try? JSONEncoder().encode(Array(messages.suffix(Self.maxStoredMessages))) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantMessage.swift SpotlessMac/Assistant/ConversationStore.swift
scripts/test.sh ConversationStoreTests
```
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant SpotlessMacTests/ConversationStoreTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): conversation messages and persistence"
```

---

### Task 11: AssistantViewModel (streaming, tool loop, fallback, plans, disclosure)

**Files:**
- Create: `SpotlessMac/Assistant/AssistantViewModel.swift`
- Create: `SpotlessMacTests/AssistantViewModelTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–10.
- Produces:
  ```swift
  @Observable @MainActor final class AssistantViewModel {
      struct Dependencies {
          var settingsStore: AssistantSettingsStore
          var keyStore: any APIKeyStoring
          var makeClient: @MainActor (AssistantSettings, String) throws -> any LLMClient
          var snapshot: @MainActor () -> SystemSnapshot
          var stagePlan: @MainActor (AssistantPlan) -> Void
          var conversationStore: ConversationStore?
          var homePath: String
          var now: @MainActor () -> Date = { Date() }
      }
      static let maxToolRounds = 4
      static let historyLimit = 20
      init(dependencies:)
      private(set) var messages: [AssistantMessage]
      private(set) var settings: AssistantSettings
      private(set) var hasAPIKey: Bool
      private(set) var isStreaming: Bool
      private(set) var statusLine: String?
      var draft: String
      var isCloudDisclosurePresented: Bool
      var isConfigured: Bool
      func currentSnapshot() -> SystemSnapshot
      func reloadSettings()
      func send(_ text: String? = nil)        // nil = send `draft`
      func ask(about focus: AssistantFocus)
      func acceptCloudDisclosure(); func switchToLocalAfterDisclosure(); func cancelCloudDisclosure()
      func stop(); func retry(); func newConversation()
      func openPlan(messageID: UUID); func dismissPlan(messageID: UUID)
      func currentAPIKey() -> String
      func saveSettings(_ settings: AssistantSettings, apiKey: String)
      func fetchModels(for settings: AssistantSettings, apiKey: String) async throws -> [String]
      func checkConnection(for settings: AssistantSettings, apiKey: String) async -> ConnectionCheckResult
      func waitUntilIdle() async               // tests
  }
  ```

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/AssistantViewModelTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

@MainActor
final class AssistantViewModelTests: XCTestCase {
    private var staged: [AssistantPlan] = []
    private var settingsStore: AssistantSettingsStore!

    private func makeViewModel(
        _ client: FakeLLMClient,
        provider: AssistantProvider = .ollamaLocal,
        toolMode: AssistantToolMode = .auto,
        conversationStore: ConversationStore? = nil,
        snapshot: SystemSnapshot = .sample()
    ) -> AssistantViewModel {
        settingsStore = AssistantSettingsStore(defaults: makeDefaults())
        var settings = AssistantSettings()
        settings.switchProvider(to: provider)
        settings.toolMode = toolMode
        settingsStore.save(settings)
        staged = []
        return AssistantViewModel(dependencies: .init(
            settingsStore: settingsStore,
            keyStore: FakeKeyStore("key"),
            makeClient: { _, _ in client },
            snapshot: { snapshot },
            stagePlan: { [unowned self] plan in self.staged.append(plan) },
            conversationStore: conversationStore,
            homePath: SystemSnapshot.testHome,
            now: { SystemSnapshot.testDate }
        ))
    }

    private func sendAndWait(_ vm: AssistantViewModel, _ text: String) async {
        vm.send(text)
        await vm.waitUntilIdle()
    }

    func testStreamsTextIntoAssistantMessage() async {
        let client = FakeLLMClient([.events([.text("Это "), .text("кеш Xcode."), .done])])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "Что такое DerivedData?")
        XCTAssertEqual(vm.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(vm.messages[1].text, "Это кеш Xcode.")
        XCTAssertEqual(vm.messages[1].status, .complete)
        XCTAssertFalse(vm.isStreaming)
        let request = client.requests[0]
        XCTAssertEqual(request.messages.first?.role, .system)
        XCTAssertTrue(request.messages[1].content.contains("Снимок системы"))
        XCTAssertEqual(request.messages.last?.content, "Что такое DerivedData?")
        XCTAssertFalse(request.tools.isEmpty)
    }

    func testToolLoopFeedsResultsBack() async {
        let call = ToolCall(id: "call_1", name: "list_items", argumentsJSON: #"{"category":"logs"}"#)
        let client = FakeLLMClient([.events([.toolCalls([call]), .done]), .events([.text("Логи можно удалить."), .done])])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "Что с логами?")
        XCTAssertEqual(client.requests.count, 2)
        let second = client.requests[1].messages
        XCTAssertEqual(second[second.count - 2].toolCalls, [call])
        XCTAssertEqual(second.last?.role, .tool)
        XCTAssertTrue(second.last?.content.contains("c5 |") ?? false)
        XCTAssertEqual(vm.messages.last?.text, "Логи можно удалить.")
    }

    func testToolRoundsAreCapped() async {
        let call = ToolCall(id: "c", name: "item_details", argumentsJSON: #"{"id":"c1"}"#)
        let steps = Array(repeating: FakeLLMClient.Step.events([.toolCalls([call]), .done]), count: 6)
        let client = FakeLLMClient(steps)
        let vm = makeViewModel(client)
        await sendAndWait(vm, "?")
        XCTAssertEqual(client.requests.count, AssistantViewModel.maxToolRounds + 1)
        XCTAssertTrue(client.requests.last?.tools.isEmpty ?? false)
        XCTAssertEqual(vm.messages.last?.status, .complete)
    }

    func testAutoFallsBackWhenToolsUnsupported() async {
        let reply = "Почистите кеши.\n```spotless-plan\n{\"items\":[\"c1\",\"c3\"],\"reason\":\"кеши\"}\n```"
        let client = FakeLLMClient([.failure(LLMError.toolsUnsupported), .events([.text(reply), .done])])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "Освободи место")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[1].tools.isEmpty)
        XCTAssertTrue(client.requests[1].messages[0].content.contains("```spotless-plan"))
        XCTAssertEqual(settingsStore.toolSupport(for: vm.settings.toolSupportKey), false)
        XCTAssertEqual(vm.messages.last?.text, "Почистите кеши.")
        XCTAssertEqual(vm.messages.last?.plan?.itemIDs.count, 2)
    }

    func testRemembersToolSupportAndOffModeSendsNoTools() async {
        let client = FakeLLMClient([.events([.text("ok"), .done])])
        let vm = makeViewModel(client, toolMode: .off)
        await sendAndWait(vm, "?")
        XCTAssertTrue(client.requests[0].tools.isEmpty)
        XCTAssertTrue(client.requests[0].messages[0].content.contains("```spotless-plan"))
    }

    func testProposePlanCreatesCardButStagesOnlyOnOpen() async {
        let call = ToolCall(id: "p", name: "propose_plan", argumentsJSON: #"{"items":["c1"],"reason":"DerivedData"}"#)
        let client = FakeLLMClient([.events([.toolCalls([call]), .done]), .events([.text("Предлагаю удалить DerivedData."), .done])])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "Освободи место")
        guard let message = vm.messages.last else { return XCTFail("no message") }
        XCTAssertEqual(message.plan?.itemIDs.count, 1)
        XCTAssertTrue(staged.isEmpty)
        vm.openPlan(messageID: message.id)
        XCTAssertEqual(staged.count, 1)
        vm.dismissPlan(messageID: message.id)
        XCTAssertTrue(vm.messages.last?.planDismissed ?? false)
    }

    // Review focus 1: tool proposal wins over a text block.
    func testToolProposalWinsOverTextBlock() async {
        let call = ToolCall(id: "p", name: "propose_plan", argumentsJSON: #"{"items":["c1"]}"#)
        let text = "План.\n```spotless-plan\n{\"items\":[\"c3\",\"c5\"]}\n```"
        let client = FakeLLMClient([.events([.toolCalls([call]), .done]), .events([.text(text), .done])])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "?")
        XCTAssertEqual(vm.messages.last?.plan?.itemIDs.count, 1)
        XCTAssertEqual(vm.messages.last?.text, "План.")
    }

    func testErrorsAreShownWithSettingsHint() async {
        let client = FakeLLMClient([.failure(LLMError.unauthorized)])
        let vm = makeViewModel(client)
        await sendAndWait(vm, "?")
        let message = vm.messages.last
        XCTAssertEqual(message?.status, .failed)
        XCTAssertEqual(message?.errorText, LLMError.unauthorized.userMessage)
        XCTAssertEqual(message?.errorOpensSettings, true)
    }

    // Review focus 5: partial answer then dropped stream.
    func testInterruptedStreamKeepsPartialText() async {
        final class DroppingClient: LLMClient, @unchecked Sendable {
            func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.text("Частично"))
                    continuation.finish(throwing: LLMError.streamInterrupted)
                }
            }
            func listModels() async throws -> [String] { [] }
        }
        settingsStore = AssistantSettingsStore(defaults: makeDefaults())
        var settings = AssistantSettings()
        settings.switchProvider(to: .ollamaLocal)
        settingsStore.save(settings)
        let vm = AssistantViewModel(dependencies: .init(
            settingsStore: settingsStore, keyStore: FakeKeyStore(), makeClient: { _, _ in DroppingClient() },
            snapshot: { .sample() }, stagePlan: { _ in }, conversationStore: nil, homePath: SystemSnapshot.testHome))
        await sendAndWait(vm, "?")
        XCTAssertEqual(vm.messages.last?.text, "Частично")
        XCTAssertEqual(vm.messages.last?.status, .interrupted)
        XCTAssertNotNil(vm.messages.last?.errorText)
        vm.retry()
        await vm.waitUntilIdle()
        XCTAssertEqual(vm.messages.count, 2)
    }

    func testStopMarksMessageStopped() async {
        let client = FakeLLMClient([.hang])
        let vm = makeViewModel(client)
        vm.send("?")
        XCTAssertTrue(vm.isStreaming)
        try? await Task.sleep(for: .milliseconds(50))
        vm.stop()
        await vm.waitUntilIdle()
        XCTAssertEqual(vm.messages.last?.status, .stopped)
        XCTAssertFalse(vm.isStreaming)
    }

    // Review focus 4: new conversation while streaming.
    func testNewConversationWhileStreaming() async {
        let client = FakeLLMClient([.hang])
        let vm = makeViewModel(client)
        vm.send("?")
        vm.newConversation()
        await vm.waitUntilIdle()
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isStreaming)
    }

    func testCloudDisclosureGatesFirstSend() async {
        let client = FakeLLMClient([.events([.text("ok"), .done])])
        let vm = makeViewModel(client, provider: .ollamaCloud)
        vm.draft = "Почему диск заполнен?"
        vm.send()
        XCTAssertTrue(vm.isCloudDisclosurePresented)
        XCTAssertTrue(client.requests.isEmpty)
        vm.acceptCloudDisclosure()
        await vm.waitUntilIdle()
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(vm.draft, "")
        XCTAssertTrue(settingsStore.cloudDisclosureAccepted)
    }

    func testCloudRequestsAreRedactedAndAnswerRestored() async {
        let client = FakeLLMClient([.events([.text("Папка <папка-1> — это зависимости."), .done])])
        let vm = makeViewModel(client, provider: .ollamaCloud)
        settingsStore.cloudDisclosureAccepted = true
        await sendAndWait(vm, "Можно удалить /Users/tester/Projects/secret-client/node_modules?")
        let everything = client.requests[0].messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(everything.contains("/Users/tester"))
        XCTAssertFalse(everything.contains("secret-client"))
        XCTAssertTrue(everything.contains("<папка-1>"))
        XCTAssertEqual(vm.messages.last?.text, "Папка secret-client — это зависимости.")
        XCTAssertTrue(vm.messages.first?.text.contains("secret-client") ?? false, "local history keeps real text")
    }

    func testAskAboutFocusSendsCard() async {
        let client = FakeLLMClient([.events([.text("ok"), .done])])
        let vm = makeViewModel(client)
        vm.ask(about: AssistantFocus(title: "DerivedData", path: "/Users/tester/Library/Developer/Xcode/DerivedData", facts: ["Размер: 9,8 ГБ"]))
        await vm.waitUntilIdle()
        let question = client.requests[0].messages.last?.content ?? ""
        XCTAssertTrue(question.hasPrefix("Что это и можно ли это удалить?"))
        XCTAssertTrue(question.contains("Путь: /Users/tester/Library/Developer/Xcode/DerivedData"))
        XCTAssertTrue(question.contains("- Размер: 9,8 ГБ"))
    }

    func testPersistsAndRestoresConversation() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "assistant-vm-\(UUID().uuidString)")
        let store = ConversationStore(fileURL: dir.appending(path: "c.json"))
        let vm = makeViewModel(FakeLLMClient([.events([.text("ok"), .done])]), conversationStore: store)
        await sendAndWait(vm, "привет")
        let restored = makeViewModel(FakeLLMClient([]), conversationStore: store)
        XCTAssertEqual(restored.messages.map(\.text), ["привет", "ok"])
    }

    func testIsConfiguredRequiresKeyForCloud() {
        settingsStore = AssistantSettingsStore(defaults: makeDefaults())
        let vm = AssistantViewModel(dependencies: .init(
            settingsStore: settingsStore, keyStore: FakeKeyStore(""), makeClient: { _, _ in FakeLLMClient([]) },
            snapshot: { .sample() }, stagePlan: { _ in }, conversationStore: nil, homePath: SystemSnapshot.testHome))
        XCTAssertFalse(vm.isConfigured)
        vm.saveSettings(vm.settings, apiKey: "abc")
        XCTAssertTrue(vm.isConfigured)
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantViewModelTests.swift
scripts/test.sh AssistantViewModelTests
```
Expected: build error `cannot find 'AssistantViewModel' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/AssistantViewModel.swift`:
```swift
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
        var stagePlan: @MainActor (AssistantPlan) -> Void
        var conversationStore: ConversationStore?
        var homePath: String
        var now: @MainActor () -> Date = { Date() }
    }

    static let maxToolRounds = 4
    static let historyLimit = 20

    private(set) var messages: [AssistantMessage]
    private(set) var settings: AssistantSettings
    private(set) var hasAPIKey: Bool
    private(set) var isStreaming = false
    private(set) var statusLine: String?
    var draft = ""
    var isCloudDisclosurePresented = false

    private let deps: Dependencies
    private var redactor: PathRedactor
    private var pendingText: String?
    private var pendingFromDraft = false
    private var streamTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        deps = dependencies
        settings = dependencies.settingsStore.load()
        hasAPIKey = !dependencies.keyStore.readKey().isEmpty
        messages = dependencies.conversationStore?.load() ?? []
        redactor = PathRedactor(homePath: dependencies.homePath)
    }

    var isConfigured: Bool {
        !settings.trimmedModel.isEmpty && (!settings.provider.requiresAPIKey || hasAPIKey)
    }

    func currentSnapshot() -> SystemSnapshot { deps.snapshot() }

    func reloadSettings() {
        settings = deps.settingsStore.load()
        hasAPIKey = !deps.keyStore.readKey().isEmpty
    }

    // MARK: Conversation

    func send(_ text: String? = nil) {
        let fromDraft = text == nil
        let trimmed = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        if settings.sendsDataOffDevice && !deps.settingsStore.cloudDisclosureAccepted {
            pendingText = trimmed
            pendingFromDraft = fromDraft
            isCloudDisclosurePresented = true
            return
        }
        if fromDraft { draft = "" }
        messages.append(.user(trimmed, at: deps.now()))
        startResponse()
    }

    func ask(about focus: AssistantFocus) {
        let facts = focus.facts.map { "- \($0)" }.joined(separator: "\n")
        send("Что это и можно ли это удалить?\n\n\(focus.title)\nПуть: \(focus.path)\n\(facts)")
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
    }

    func stop() {
        streamTask?.cancel()
    }

    func retry() {
        guard !isStreaming, let last = messages.last, last.role == .assistant,
              [.failed, .interrupted, .stopped].contains(last.status) else { return }
        messages.removeLast()
        startResponse()
    }

    func newConversation() {
        streamTask?.cancel()
        messages = []
        redactor = PathRedactor(homePath: deps.homePath)
        persist()
    }

    func openPlan(messageID: UUID) {
        guard let plan = messages.first(where: { $0.id == messageID })?.plan, !plan.isEmpty else { return }
        deps.stagePlan(plan)
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

    private func resumePending() {
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
        let snapshot = Self.prepared(deps.snapshot(), redacts: redacts)
        do {
            let client = try deps.makeClient(settings, deps.keyStore.readKey())
            var toolsEnabled = toolsEnabled(for: settings)
            var conversation = wireHistory(excluding: messageID, redacts: redacts)
            var transcript = ""
            var rounds = 0
            var proposal: PlanProposal?

            while true {
                let offerTools = toolsEnabled && rounds < Self.maxToolRounds
                let request = ChatRequest(
                    model: settings.trimmedModel,
                    messages: systemMessages(snapshot: snapshot, toolsEnabled: toolsEnabled, redacts: redacts) + conversation,
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
                    let outcome = AssistantToolbox.execute(call, snapshot: snapshot) { path in
                        redacts ? self.redactor.redact(path) : path
                    }
                    if let proposed = outcome.proposal { proposal = proposed }
                    conversation.append(WireMessage(role: .tool, content: outcome.resultText, toolCallID: call.id, toolName: call.name))
                }
                statusLine = nil
                if !transcript.isEmpty && !transcript.hasSuffix("\n") { transcript += "\n\n" }
            }

            let parsed = PlanParser.extract(from: transcript)
            let plan = (proposal ?? parsed.proposal).map { PlanResolver.resolve($0, in: snapshot) }
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

    private func systemMessages(snapshot: SystemSnapshot, toolsEnabled: Bool, redacts: Bool) -> [WireMessage] {
        let context = SnapshotRenderer.render(snapshot) { path in redacts ? self.redactor.redact(path) : path }
        return [
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
```

- [ ] **Step 4: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantViewModel.swift
scripts/test.sh AssistantViewModelTests
```
Expected: `Executed 16 tests, with 0 failures`. If `testStopMarksMessageStopped` is flaky because the hanging stream is not cancelled, verify that `FakeLLMClient.Step.hang` relies on consumer cancellation; `AsyncThrowingStream` ends iteration when the consuming task is cancelled, and `try Task.checkCancellation()` then throws `CancellationError`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/AssistantViewModel.swift SpotlessMacTests/AssistantViewModelTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): view model with streaming, tool loop and plan cards"
```

---

### Task 12: No-delete isolation guard and CLAUDE.md rule 6

**Files:**
- Create: `SpotlessMacTests/AssistantIsolationTests.swift`
- Modify: `CLAUDE.md` (Safety rules section)

**Interfaces:**
- Consumes: the `SpotlessMac/Assistant/` folder contents; `AssistantTool`, `AssistantToolbox`.
- Produces: a failing test whenever the module gains access to deletion/process APIs.

- [ ] **Step 1: Write the guard test**

`SpotlessMacTests/AssistantIsolationTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

// The assistant must never be able to delete anything. These checks keep the
// Assistant module away from every deletion, process and file-mutation API.
final class AssistantIsolationTests: XCTestCase {
    private let forbidden = [
        "trashItem", "removeItem", "moveItem", "copyItem", "unlink(", "FileManager", "Process(",
        "NSWorkspace", "ScanEngine", "ScanViewModel", "DockerCleanupViewModel", "DockerClient",
        "DockerCommandRunner", "UninstallViewModel", "UninstallEngine", "deleteWithProgress",
        "cleanCache", "URL(fileURLWithPath",
    ]
    private let allowances: [String: Set<String>] = ["ConversationStore.swift": ["FileManager"]]
    private let allowedFileManagerMembers: Set<String> = ["urls", "createDirectory", "homeDirectoryForCurrentUser"]

    private var assistantSources: [URL] {
        get throws {
            let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "SpotlessMac/Assistant")
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
    }

    func testAssistantModuleHasNoAccessToDeletionOrProcessAPIs() throws {
        let files = try assistantSources
        XCTAssertGreaterThan(files.count, 10, "Assistant sources not found")
        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let allowed = allowances[file.lastPathComponent] ?? []
            for token in forbidden where !allowed.contains(token) && source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }
        XCTAssertEqual(violations, [], "Assistant must never reach deletion or process APIs")
    }

    func testConversationStoreUsesOnlyHarmlessFileManagerMembers() throws {
        let file = try XCTUnwrap(try assistantSources.first { $0.lastPathComponent == "ConversationStore.swift" })
        let source = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"FileManager\.default\.(\w+)"#)
        let members = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertFalse(members.isEmpty)
        XCTAssertEqual(Set(members).subtracting(allowedFileManagerMembers), [])
    }

    func testToolSetIsClosedAndReadOnly() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan"])
        for name in ["delete_file", "trash", "run_shell", "rm", "exec"] {
            let outcome = AssistantToolbox.execute(ToolCall(id: "x", name: name, argumentsJSON: "{}"), snapshot: .sample()) { $0 }
            XCTAssertNil(outcome.proposal, name)
            XCTAssertTrue(outcome.resultText.contains("не существует"), name)
        }
    }
}
```

- [ ] **Step 2: Register and run**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantIsolationTests.swift
scripts/test.sh AssistantIsolationTests
```
Expected: `Executed 3 tests, with 0 failures`. If a violation is reported, fix the offending Assistant file (often a comment that mentions a forbidden word) — never weaken the token list.

- [ ] **Step 3: Prove the guard bites**

Temporarily add `// FileManager.default.removeItem` as the last line of `SpotlessMac/Assistant/PlanParser.swift`, run `scripts/test.sh AssistantIsolationTests`, expect `PlanParser.swift: removeItem` and `PlanParser.swift: FileManager` in the failure. Then remove the line and re-run to green.

- [ ] **Step 4: Add rule 6 to CLAUDE.md**

In `CLAUDE.md`, under `## Safety rules (non-negotiable)`, after item 5 (`**Never touch:** …`) add:
```markdown
6. **Assistant never deletes** — `SpotlessMac/Assistant/` has no access to deletion, process or Docker/uninstall APIs. Its only outward effect is the `stagePlan` closure, which marks existing scan items for the user's review. Enforced by `AssistantIsolationTests`; never weaken its token list.
```
And in the `## Key files` table add:
```markdown
| `Assistant/AssistantViewModel.swift` | AI cleanup assistant; receives only a snapshot closure and `stagePlan` |
```

- [ ] **Step 5: Commit**

```bash
git add SpotlessMacTests/AssistantIsolationTests.swift CLAUDE.md SpotlessMac.xcodeproj/project.pbxproj
git commit -m "test(assistant): enforce no-delete isolation; document safety rule 6"
```

---

### Task 13: Staging in ScanViewModel, snapshot builder, improvement advisor

**Files:**
- Modify: `SpotlessMac/ViewModels/ScanViewModel.swift`
- Create: `SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift`
- Create: `SpotlessMac/Assistant/ImprovementAdvisor.swift`
- Create: `SpotlessMacTests/AssistantStagingTests.swift`

**Interfaces:**
- Consumes: snapshot types (Task 6), `SnapshotRenderer` (Task 7).
- Produces:
  - `ScanViewModel`: `struct AssistantStaging: Equatable { count: Int; bytes: Int64 }`, `private(set) var lastScanAt: Date?`, `private(set) var assistantStaging: AssistantStaging?`, `var recoveryPreviewRequested: Bool`, `@discardableResult func stageSelection(_ ids: Set<UUID>) -> AssistantStaging`, `func clearAssistantStaging()`
  - `@MainActor enum AssistantSnapshotBuilder { make(scan:docker:uninstall:volume:now:) -> SystemSnapshot; readVolume() -> VolumeInfo?; focus(for: ScanItem, ownerActivity: OwnerActivity?) -> AssistantFocus; focus(for: LeftoverItem, appName: String?) -> AssistantFocus; focus(for: DockerResource) -> AssistantFocus }`
  - `struct Improvement: Equatable, Identifiable, Sendable { enum Action { ask(String), scan }; id; icon; title; detail; action }`, `enum ImprovementAdvisor { static func suggestions(for: SystemSnapshot) -> [Improvement] }`

- [ ] **Step 1: Write failing tests**

`SpotlessMacTests/AssistantStagingTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

@MainActor
final class AssistantStagingTests: XCTestCase {
    private func item(_ name: String, _ size: Int64, _ category: ScanCategory, selected: Bool = true) -> ScanItem {
        ScanItem(path: URL(filePath: "/Users/tester/Library/Caches/\(name)"), size: size, category: category, isSelected: selected)
    }

    private func scannedViewModel(_ items: [ScanItem]) async -> ScanViewModel {
        let vm = ScanViewModel(
            scanItems: { _ in items },
            deleteItems: { _ in XCTFail("staging must never delete"); return [] }
        )
        await vm.scan()
        return vm
    }

    func testStageSelectionOnlyTogglesBatchItemsAndNeverDeletes() async {
        let a = item("a", 100, .userCaches)
        let b = item("b", 200, .logs)
        let model = item("m", 999, .modelCaches, selected: false)
        let vm = await scannedViewModel([a, b, model])
        let staging = vm.stageSelection([b.id, model.id])
        XCTAssertEqual(staging, ScanViewModel.AssistantStaging(count: 1, bytes: 200))
        XCTAssertEqual(vm.items.first { $0.id == a.id }?.isSelected, false)
        XCTAssertEqual(vm.items.first { $0.id == b.id }?.isSelected, true)
        XCTAssertEqual(vm.items.first { $0.id == model.id }?.isSelected, false)
        XCTAssertEqual(vm.assistantStaging, staging)
        XCTAssertTrue(vm.recoveryPreviewRequested)
        XCTAssertEqual(vm.items.count, 3)
        vm.clearAssistantStaging()
        XCTAssertNil(vm.assistantStaging)
    }

    func testScanRecordsTimestamp() async {
        let vm = await scannedViewModel([])
        XCTAssertNotNil(vm.lastScanAt)
    }

    func testSnapshotBuilderAssignsStableIDsBySize() async {
        let small = item("small", 10, .logs)
        let big = item("big", 500, .developerCaches)
        let tieA = item("a-tie", 50, .userCaches)
        let tieB = item("b-tie", 50, .userCaches)
        let vm = await scannedViewModel([small, tieB, big, tieA])
        let snapshot = AssistantSnapshotBuilder.make(scan: vm, docker: nil, uninstall: nil, volume: nil, now: SystemSnapshot.testDate)
        XCTAssertEqual(snapshot.items.map(\.shortID), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(snapshot.items.map(\.itemID), [big.id, tieA.id, tieB.id, small.id])
        XCTAssertEqual(snapshot.categories.first?.category, .developerCaches)
        XCTAssertNotNil(snapshot.lastScanAt)
        XCTAssertEqual(snapshot.items[0].path, "/Users/tester/Library/Caches/big")
    }

    func testFocusForScanItem() {
        let focus = AssistantSnapshotBuilder.focus(for: item("DerivedData", 9_800_000_000, .developerCaches), ownerActivity: .running)
        XCTAssertEqual(focus.title, "DerivedData")
        XCTAssertTrue(focus.facts.contains { $0.hasPrefix("Категория:") })
    }

    func testAdvisorWithoutScanSuggestsScanning() {
        let suggestions = ImprovementAdvisor.suggestions(for: SystemSnapshot(takenAt: SystemSnapshot.testDate, fullDiskAccess: true))
        XCTAssertEqual(suggestions.map(\.action), [.scan])
    }

    func testAdvisorRanksLowSpaceFirstAndCaps() {
        var snapshot = SystemSnapshot.sample()
        snapshot.volume = VolumeInfo(name: "Macintosh HD", totalBytes: 500_000_000_000, availableBytes: 20_000_000_000)
        snapshot.fullDiskAccess = false
        let suggestions = ImprovementAdvisor.suggestions(for: snapshot)
        XCTAssertEqual(suggestions.first?.id, "low-space")
        XCTAssertTrue(suggestions.contains { $0.id == "fda" })
        XCTAssertTrue(suggestions.contains { $0.id == "category-developer_caches" })
        XCTAssertTrue(suggestions.contains { $0.id == "docker" })
        XCTAssertLessThanOrEqual(suggestions.count, 6)
    }

    func testAdvisorFlagsStaleScan() {
        var snapshot = SystemSnapshot.sample()
        snapshot.lastScanAt = SystemSnapshot.testDate.addingTimeInterval(-5 * 86_400)
        XCTAssertTrue(ImprovementAdvisor.suggestions(for: snapshot).contains { $0.id == "stale-scan" && $0.action == .scan })
    }
}
```

- [ ] **Step 2: Register and verify failure**

Run:
```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantStagingTests.swift
scripts/test.sh AssistantStagingTests
```
Expected: build errors `value of type 'ScanViewModel' has no member 'stageSelection'`, `cannot find 'AssistantSnapshotBuilder'`.

- [ ] **Step 3: Modify ScanViewModel**

In `SpotlessMac/ViewModels/ScanViewModel.swift`:

After `var fdaStatus: FDAStatus = .unknown` add:
```swift
    // Assistant staging: selection prepared by the assistant for the user's review.
    struct AssistantStaging: Equatable {
        let count: Int
        let bytes: Int64
    }
    private(set) var lastScanAt: Date?
    private(set) var assistantStaging: AssistantStaging?
    var recoveryPreviewRequested = false
```

In `func scan()`, replace
```swift
        do {
            items = try await scanItems(fdaStatus)
        } catch {
```
with
```swift
        assistantStaging = nil
        do {
            items = try await scanItems(fdaStatus)
            lastScanAt = Date()
        } catch {
```

In `func delete(items targetItems:)`, after `cleanupReports = await reports(…)` and before `return .completed(failures)` add:
```swift
        assistantStaging = nil
```

After `func selectNone()` add:
```swift
    // Marks only existing batch-cleanable items; never deletes anything.
    @discardableResult
    func stageSelection(_ ids: Set<UUID>) -> AssistantStaging {
        var count = 0
        var bytes: Int64 = 0
        for index in items.indices where items[index].category.isBatchCleanable {
            let selected = ids.contains(items[index].id)
            items[index].isSelected = selected
            if selected {
                count += 1
                bytes += items[index].size
            }
        }
        let staging = AssistantStaging(count: count, bytes: bytes)
        assistantStaging = staging
        recoveryPreviewRequested = true
        return staging
    }

    func clearAssistantStaging() {
        assistantStaging = nil
    }
```

- [ ] **Step 4: Implement builder and advisor**

`SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift`:
```swift
import Foundation

// Copies live view-model state into the assistant's immutable snapshot.
// Lives outside SpotlessMac/Assistant/ on purpose: the assistant never sees these objects.
@MainActor
enum AssistantSnapshotBuilder {
    static func make(
        scan: ScanViewModel,
        docker: DockerCleanupViewModel?,
        uninstall: UninstallViewModel?,
        volume: VolumeInfo?,
        now: Date
    ) -> SystemSnapshot {
        let sorted = scan.items.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.path.path < $1.path.path
        }
        let items = sorted.enumerated().map { index, item in
            SnapshotItem(
                shortID: "c\(index + 1)", itemID: item.id, path: item.path.path(percentEncoded: false),
                bytes: item.size, category: item.category, disposition: item.cleanupPolicy.disposition,
                reason: item.cleanupReason, modifiedAt: item.modifiedAt, owner: item.owner
            )
        }
        let categories = Dictionary(grouping: items, by: \.category)
            .map { CategorySummary(category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
        let fda: Bool? = switch scan.fdaStatus {
        case .granted: true
        case .denied: false
        case .unknown: nil
        }
        return SystemSnapshot(
            takenAt: now,
            volume: volume,
            fullDiskAccess: fda,
            lastScanAt: scan.lastScanAt,
            categories: categories,
            items: items,
            docker: docker.flatMap(dockerInfo),
            leftovers: uninstall.flatMap(leftoverInfo),
            lastCleanup: scan.cleanupReport.map {
                LastCleanupInfo(trashedBytes: $0.trashedBytes, observedFreeSpaceDelta: $0.observedFreeSpaceDelta)
            }
        )
    }

    static func readVolume() -> VolumeInfo? {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]),
              let total = values.volumeTotalCapacity else { return nil }
        return VolumeInfo(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            totalBytes: Int64(total),
            availableBytes: Int64(values.volumeAvailableCapacity ?? 0)
        )
    }

    static func focus(for item: ScanItem, ownerActivity: OwnerActivity?) -> AssistantFocus {
        var facts = [
            "Категория: \(item.category.displayName)",
            "Размер: \(item.formattedSize)",
            "Политика: \(item.cleanupPolicy.disposition.label)",
            "Причина: \(item.cleanupReason)",
        ]
        if let modified = item.modifiedAt { facts.append("Изменён: \(SnapshotRenderer.date(modified))") }
        if let owner = item.owner {
            facts.append("Владелец: \(owner)\(ownerActivity == .running ? " (сейчас запущен)" : "")")
        }
        return AssistantFocus(title: item.path.lastPathComponent, path: item.path.path(percentEncoded: false), facts: facts)
    }

    static func focus(for leftover: LeftoverItem, appName: String?) -> AssistantFocus {
        var facts = [
            "Расположение: \(leftover.location)",
            "Тип: \(leftover.dispositionLabel)",
            "Размер: \(leftover.formattedSize)",
            leftover.confidence == .exact
                ? "Совпадение: точное, по идентификатору программы"
                : "Совпадение: только по имени — возможно, не связано с программой",
        ]
        if let appName { facts.insert("Остаток программы «\(appName)»", at: 0) }
        return AssistantFocus(title: leftover.path.lastPathComponent, path: leftover.path.path(percentEncoded: false), facts: facts)
    }

    static func focus(for resource: DockerResource) -> AssistantFocus {
        let risk = switch resource.risk {
        case .rebuildable: "восстановимо (пересоздаётся при сборке или загрузке)"
        case .review: "проверьте перед удалением"
        case .dataLoss: "риск потери данных"
        }
        var facts = ["Тип: \(resource.kind.displayName)", "Описание: \(resource.detail)", "Размер: \(resource.formattedSize)", "Риск: \(risk)"]
        if let used = resource.lastUsedAt ?? resource.createdAt { facts.append("Последнее использование: \(SnapshotRenderer.date(used))") }
        return AssistantFocus(title: resource.name, path: "Docker: \(resource.kind.displayName)", facts: facts)
    }

    private static func dockerInfo(_ viewModel: DockerCleanupViewModel) -> DockerInfo? {
        let status: String
        switch viewModel.availability {
        case .checking: return nil
        case .cliMissing: status = "Docker CLI не установлен"
        case .daemonUnavailable: status = "Docker не запущен"
        case .ready: status = "Docker запущен"
        }
        let kinds = DockerResourceKind.allCases.compactMap { kind -> DockerKindSummary? in
            let resources = viewModel.resources.filter { $0.kind == kind }
            guard !resources.isEmpty else { return nil }
            return DockerKindSummary(
                kindName: kind.displayName, count: resources.count,
                bytes: resources.compactMap(\.size).reduce(0, +),
                dataLossCount: resources.filter { $0.risk == .dataLoss }.count
            )
        }
        return DockerInfo(
            status: status,
            virtualDiskBytes: viewModel.storageSummary.virtualDiskAllocatedBytes,
            reclaimableBytes: viewModel.storageSummary.engineReclaimableBytes,
            kinds: kinds
        )
    }

    private static func leftoverInfo(_ viewModel: UninstallViewModel) -> LeftoverInfo? {
        guard let app = viewModel.selectedApp, !viewModel.leftovers.isEmpty else { return nil }
        let leftovers = viewModel.leftovers
        return LeftoverInfo(
            appName: app.name, count: leftovers.count,
            exactCount: leftovers.filter { $0.confidence == .exact }.count,
            nameOnlyCount: leftovers.filter { $0.confidence == .nameOnly }.count,
            bytes: leftovers.reduce(0) { $0 + $1.size }
        )
    }
}
```

`SpotlessMac/Assistant/ImprovementAdvisor.swift`:
```swift
import Foundation

struct Improvement: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case ask(String)
        case scan
    }

    let id: String
    let icon: String
    let title: String
    let detail: String
    let action: Action
}

// Local, LLM-free "what can be improved" list for the assistant tab.
enum ImprovementAdvisor {
    static let gigabyte: Int64 = 1_000_000_000
    static let maxSuggestions = 6
    static let advisable: Set<ScanCategory> = [
        .userCaches, .developerCaches, .logs, .modelCaches, .knownAppCaches, .projectArtifacts, .oldInstallers,
    ]

    static func suggestions(for snapshot: SystemSnapshot) -> [Improvement] {
        var weighted: [(weight: Int64, improvement: Improvement)] = []
        if let volume = snapshot.volume, volume.freeFraction < 0.1 {
            weighted.append((Int64.max, Improvement(
                id: "low-space", icon: "exclamationmark.triangle.fill",
                title: "Мало свободного места: \(SnapshotRenderer.percent(volume.freeFraction))",
                detail: "Свободно \(SnapshotRenderer.bytes(volume.availableBytes)) из \(SnapshotRenderer.bytes(volume.totalBytes))",
                action: .ask("Почему диск заполнен и что освободить в первую очередь?")
            )))
        }
        if snapshot.fullDiskAccess == false {
            weighted.append((Int64.max - 1, Improvement(
                id: "fda", icon: "lock.shield",
                title: "Нет полного доступа к диску",
                detail: "Часть системных кешей и логов не видна",
                action: .ask("Зачем SpotlessMac нужен полный доступ к диску и что без него не найдётся?")
            )))
        }
        guard let scanDate = snapshot.lastScanAt else {
            weighted.append((Int64.max - 2, Improvement(
                id: "scan", icon: "magnifyingglass",
                title: "Сканирование ещё не проводилось",
                detail: "Запустите поиск, чтобы ассистент видел кеши и крупные файлы",
                action: .scan
            )))
            return Array(weighted.sorted { $0.weight > $1.weight }.map(\.improvement).prefix(maxSuggestions))
        }
        if snapshot.takenAt.timeIntervalSince(scanDate) > 3 * 86_400 {
            weighted.append((Int64.max - 3, Improvement(
                id: "stale-scan", icon: "clock.arrow.circlepath",
                title: "Результаты сканирования устарели",
                detail: "Последнее сканирование: \(SnapshotRenderer.date(scanDate))",
                action: .scan
            )))
        }
        for summary in snapshot.categories where summary.bytes >= gigabyte && advisable.contains(summary.category) {
            weighted.append((summary.bytes, Improvement(
                id: "category-\(summary.category.rawValue)", icon: "folder.badge.minus",
                title: "\(summary.category.displayName): \(SnapshotRenderer.bytes(summary.bytes))",
                detail: "\(summary.count) элементов",
                action: .ask("Что из категории «\(summary.category.displayName)» можно безопасно удалить?")
            )))
        }
        if let docker = snapshot.docker, let reclaimable = docker.reclaimableBytes, reclaimable >= gigabyte {
            weighted.append((reclaimable, Improvement(
                id: "docker", icon: "shippingbox",
                title: "Docker: можно освободить \(SnapshotRenderer.bytes(reclaimable))",
                detail: docker.status,
                action: .ask("Что можно безопасно удалить из Docker?")
            )))
        }
        if let leftovers = snapshot.leftovers, leftovers.count > 0 {
            weighted.append((leftovers.bytes, Improvement(
                id: "leftovers", icon: "trash.slash",
                title: "Остатки «\(leftovers.appName)»: \(SnapshotRenderer.bytes(leftovers.bytes))",
                detail: "\(leftovers.count) элементов",
                action: .ask("Какие остатки программы «\(leftovers.appName)» можно удалить?")
            )))
        }
        return Array(weighted.sorted { $0.weight > $1.weight }.map(\.improvement).prefix(maxSuggestions))
    }
}
```

- [ ] **Step 5: Register, run, verify pass**

Run:
```bash
scripts/xcodeproj-add.py app ViewModels SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/ImprovementAdvisor.swift
scripts/test.sh AssistantStagingTests AssistantIsolationTests SmartCareLifecycleTests SmartCareSelectionTests
```
Expected: all pass (existing ScanViewModel tests stay green).

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/ViewModels/ScanViewModel.swift SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift SpotlessMac/Assistant/ImprovementAdvisor.swift SpotlessMacTests/AssistantStagingTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): selection staging, snapshot builder, local improvement hints"
```

---

### Task 14: Markdown parser port and chat views

**Files:**
- Create: `SpotlessMac/Assistant/AssistantMarkdownBlocks.swift` (ported from wooffoow)
- Create: `SpotlessMac/App/AssistantMarkdownView.swift`
- Create: `SpotlessMac/App/AssistantMessageView.swift`
- Create: `SpotlessMac/App/AssistantView.swift`
- Create: `SpotlessMacTests/AssistantMarkdownBlocksTests.swift`

**Interfaces:**
- Consumes: `AssistantViewModel` (Task 11), `Improvement` (Task 13), `AssistantMessage`, `AssistantPlan`.
- Produces: `enum AssistantMarkdownBlock`, `enum AssistantMarkdownBlocks { static func parse(_:) -> [AssistantMarkdownBlock] }`; views `AssistantMarkdownView(markdown:)`, `AssistantMessageView(message:canRetry:onOpenPlan:onDismissPlan:onRetry:onOpenSettings:)`, `AssistantPlanCard(plan:onOpen:onDismiss:)`, `CloudDisclosureSheet(onAccept:onUseLocal:onCancel:)`, `AssistantView(viewModel:onOpenSettings:onScan:)`.

- [ ] **Step 1: Port the parser**

Run:
```bash
awk '/^struct SummaryMarkdownView/{exit} {print}' /Users/evgeniy/MyProjects/wooffoow/Sources/WooffoowUI/Report/SummaryMarkdownView.swift \
  | sed 's/SummaryMarkdown/AssistantMarkdown/g' > SpotlessMac/Assistant/AssistantMarkdownBlocks.swift
grep -n "^import\|^enum\|wf\|WF" SpotlessMac/Assistant/AssistantMarkdownBlocks.swift
```
Expected: `import SwiftUI`, `enum AssistantMarkdownBlock`, `enum AssistantMarkdownBlocks`, and no `wf`/`WF` references. Replace `import SwiftUI` with `import Foundation` at the top of the file (the parser needs no UI).

- [ ] **Step 2: Write parser tests**

`SpotlessMacTests/AssistantMarkdownBlocksTests.swift`:
```swift
import XCTest
@testable import SpotlessMac

final class AssistantMarkdownBlocksTests: XCTestCase {
    func testHeadingsListsAndParagraphs() {
        let blocks = AssistantMarkdownBlocks.parse("## Вердикт\nБезопасно.\n\n- кеш\n- логи\n1. шаг")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Вердикт"),
            .paragraph("Безопасно."),
            .bullet(text: "кеш", depth: 0),
            .bullet(text: "логи", depth: 0),
            .numbered(marker: "1.", text: "шаг"),
        ])
    }

    func testCodeAndTable() {
        let blocks = AssistantMarkdownBlocks.parse("```\nrm -rf\n```\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.code("rm -rf"), .table(header: ["A", "B"], rows: [["1", "2"]])])
    }
}
```

Run:
```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/AssistantMarkdownBlocks.swift
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/AssistantMarkdownBlocksTests.swift
scripts/test.sh AssistantMarkdownBlocksTests AssistantIsolationTests
```
Expected: pass.

- [ ] **Step 3: Write the views**

`SpotlessMac/App/AssistantMarkdownView.swift`:
```swift
import SwiftUI

struct AssistantMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AssistantMarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(.system(size: level <= 2 ? 15 : 13, weight: .semibold))
                .padding(.top, 4)
        case let .bullet(text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(Self.inline(text))
            }
            .font(.system(size: 13))
            .padding(.leading, CGFloat(depth) * 12)
        case let .numbered(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(Self.inline(text))
            }
            .font(.system(size: 13))
        case let .paragraph(text):
            Text(Self.inline(text)).font(.system(size: 13))
        case let .code(text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.trackBackground, in: RoundedRectangle(cornerRadius: Theme.radiusChip))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(header, rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell)).fontWeight(.semibold)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                        }
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
```

`SpotlessMac/App/AssistantMessageView.swift`:
```swift
import SwiftUI

struct AssistantMessageView: View {
    let message: AssistantMessage
    var canRetry: Bool
    var onOpenPlan: () -> Void
    var onDismissPlan: () -> Void
    var onRetry: () -> Void
    var onOpenSettings: () -> Void

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
                AssistantMarkdownView(markdown: message.text)
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
                Text("• пути, где имя пользователя заменено на ~, а папки проектов и документов — на <папка-N>")
                Text("• сведения о диске, Docker и остатках программ")
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
```

`SpotlessMac/App/AssistantView.swift`:
```swift
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
        .sheet(isPresented: $viewModel.isCloudDisclosurePresented) {
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
```

- [ ] **Step 4: Register and build**

Run:
```bash
scripts/xcodeproj-add.py app App SpotlessMac/App/AssistantMarkdownView.swift SpotlessMac/App/AssistantMessageView.swift SpotlessMac/App/AssistantView.swift
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
scripts/test.sh AssistantIsolationTests AssistantMarkdownBlocksTests
```
Expected: `** BUILD SUCCEEDED **`; tests pass.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/AssistantMarkdownBlocks.swift SpotlessMac/App/AssistantMarkdownView.swift SpotlessMac/App/AssistantMessageView.swift SpotlessMac/App/AssistantView.swift SpotlessMacTests/AssistantMarkdownBlocksTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): chat views, plan card, cloud disclosure"
```

---

### Task 15: Wiring — tab, rail, settings card, preview staging banner

**Files:**
- Create: `SpotlessMac/App/AssistantSettingsCard.swift`
- Modify: `SpotlessMac/App/ContentView.swift`
- Modify: `SpotlessMac/App/CareRailView.swift`
- Modify: `SpotlessMac/App/SpotlessMacSettingsView.swift`
- Modify: `SpotlessMac/App/UninstallerView.swift`
- Modify: `SpotlessMac/App/DiskOverviewView.swift`
- Modify: `SpotlessMac/App/StorageRecoveryView.swift`

**Interfaces:**
- Consumes: `AssistantViewModel` + `Dependencies` (Task 11), `AssistantSnapshotBuilder` (Task 13), `ScanViewModel.stageSelection/assistantStaging/recoveryPreviewRequested/clearAssistantStaging` (Task 13), `AssistantView` (Task 14), `LLMClientFactory`, `KeychainAPIKeyStore`, `AssistantSettingsStore`, `ConversationStore`.
- Produces: `AppTab.assistant`; `AssistantSettingsCard(assistant:)`; `SpotlessMacSettingsView(viewModel:licenseManager:assistant:showActivation:showOnboarding:)`; `UninstallerView(viewModel:licenseManager:)`; `ContentView` owns `uninstallViewModel` and `assistant`.

- [ ] **Step 1: Add the tab**

`SpotlessMac/App/ContentView.swift` — in `enum AppTab` add `case assistant = "Ассистент"` after `case docker = "Docker"`, and change:
```swift
    static let mainTabs: [AppTab] = [.care, .cleaning, .uninstall, .diskUsage, .docker, .assistant]
```
`SpotlessMac/App/CareRailView.swift` — add `case .assistant: return "sparkles"` to `icon` and `case .assistant: return "Помощь"` to `shortLabel`.

- [ ] **Step 2: Own the assistant and uninstall view models in ContentView**

In `ContentView`, after `@State private var licenseManager = LicenseManager()` add:
```swift
    @State private var uninstallViewModel = UninstallViewModel()
    @State private var assistant: AssistantViewModel?
```
Change the badge overlay condition from `if selectedTab != .settings {` to:
```swift
            if selectedTab != .settings && selectedTab != .assistant {
```
In `.onAppear { … }` add as the first line:
```swift
            if assistant == nil { assistant = makeAssistant() }
```
In `tabContent`, change `case .uninstall:` to:
```swift
        case .uninstall:
            UninstallerView(viewModel: uninstallViewModel, licenseManager: licenseManager)
```
add before `case .settings:`:
```swift
        case .assistant:
            if let assistant {
                AssistantView(
                    viewModel: assistant,
                    onOpenSettings: { selectedTab = .settings },
                    onScan: { Task { await viewModel.scan() } }
                )
            }
```
and pass the assistant into settings:
```swift
            SpotlessMacSettingsView(
                viewModel: viewModel,
                licenseManager: licenseManager,
                assistant: assistant,
                showActivation: $showActivation,
                showOnboarding: $showOnboarding
            )
```
Add to `ContentView` (after `tabContent`):
```swift
    private func makeAssistant() -> AssistantViewModel {
        let scan = viewModel
        let docker = dockerViewModel
        let uninstall = uninstallViewModel
        let tab = $selectedTab
        return AssistantViewModel(dependencies: .init(
            settingsStore: AssistantSettingsStore(),
            keyStore: KeychainAPIKeyStore(),
            makeClient: { settings, key in try LLMClientFactory.make(settings: settings, apiKey: key) },
            snapshot: {
                AssistantSnapshotBuilder.make(scan: scan, docker: docker, uninstall: uninstall,
                                              volume: AssistantSnapshotBuilder.readVolume(), now: Date())
            },
            stagePlan: { plan in
                scan.stageSelection(Set(plan.itemIDs))
                tab.wrappedValue = .diskUsage
            },
            conversationStore: ConversationStore(fileURL: ConversationStore.defaultFileURL()),
            homePath: NSHomeDirectory()
        ))
    }
```

- [ ] **Step 3: Hoist UninstallViewModel**

In `SpotlessMac/App/UninstallerView.swift` replace `@State private var viewModel = UninstallViewModel()` with:
```swift
    var viewModel: UninstallViewModel
```
and delete the line `.onDisappear { viewModel.cancelSizing() }`. The model now lives in `ContentView`, so app sizing may finish in the background instead of being cut off on every tab switch (otherwise `.task` would never restart it, because `apps` is no longer empty). Keep `.task { if viewModel.apps.isEmpty { await viewModel.loadApps() } }` unchanged. If the compiler reports `$viewModel` usages, add `@Bindable` to the property.

- [ ] **Step 4: Open the preview when a plan is staged; show the banner**

In `SpotlessMac/App/DiskOverviewView.swift`:
- change `.sheet(isPresented: $showStorageRecovery, onDismiss: refreshDiskOverview) {` to
```swift
        .sheet(isPresented: $showStorageRecovery, onDismiss: {
            viewModel.clearAssistantStaging()
            refreshDiskOverview()
        }) {
```
- add after the `.onDisappear { analysis.cancel() }` line:
```swift
        .onChange(of: viewModel.recoveryPreviewRequested, initial: true) { _, requested in
            guard requested else { return }
            viewModel.recoveryPreviewRequested = false
            showStorageRecovery = true
        }
```

In `SpotlessMac/App/StorageRecoveryView.swift`, in `body` change
```swift
            header
            controls
```
to
```swift
            header
            if let staging = viewModel.assistantStaging { assistantBanner(staging) }
            controls
```
and add to `StorageRecoveryView`:
```swift
    private func assistantBanner(_ staging: ScanViewModel.AssistantStaging) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accentGradientStart)
            Text("Выбрано ассистентом: \(staging.count) элементов, \(ByteCountFormatter.string(fromByteCount: staging.bytes, countStyle: .file)). Проверьте список перед удалением.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Сбросить выбор") {
                viewModel.selectNone()
                viewModel.clearAssistantStaging()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.warningBackground)
    }
```

- [ ] **Step 5: Settings card**

`SpotlessMac/App/AssistantSettingsCard.swift`:
```swift
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
            }
            row("Тайм-аут") {
                Stepper("\(draft.timeoutSeconds) с", value: $draft.timeoutSeconds, in: AssistantSettings.timeoutRange, step: 10)
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
                .buttonStyle(.borderedProminent)
            }
            .buttonStyle(.bordered)

            Text("Для облачных провайдеров пути обезличиваются: имя пользователя заменяется на ~, папки проектов — на <папка-N>. Содержимое файлов не отправляется.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            reset()
        }
    }

    private var providerBinding: Binding<AssistantProvider> {
        Binding(
            get: { draft.provider },
            set: { provider in
                draft.switchProvider(to: provider)
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
```

In `SpotlessMac/App/SpotlessMacSettingsView.swift`:
- after `var licenseManager: LicenseManager` add `var assistant: AssistantViewModel? = nil`
- in the `VStack` change `generalCard` → `generalCard` followed by `assistantCard`:
```swift
                header
                generalCard
                assistantCard
                accessCard
```
- add:
```swift
    @ViewBuilder
    private var assistantCard: some View {
        if let assistant {
            settingsCard("АССИСТЕНТ", icon: "sparkles", iconColor: Theme.accentGradientStart) {
                AssistantSettingsCard(assistant: assistant)
            }
        }
    }
```

- [ ] **Step 6: Register, build, run full suite**

Run:
```bash
scripts/xcodeproj-add.py app App SpotlessMac/App/AssistantSettingsCard.swift
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
scripts/test.sh
```
Expected: `** BUILD SUCCEEDED **`; full suite passes except the pre-existing failures recorded in Task 1.

- [ ] **Step 7: Manual smoke check**

Run `./scripts/install-local-debug.sh` (or `open build/DerivedData/Build/Products/Debug/SpotlessMac.app`). Verify:
1. The rail shows «Помощь» (sparkles); the tab shows «Подключите модель» until configured.
2. Settings → «АССИСТЕНТ»: switching provider changes URL/model; token field hidden for local Ollama; «Проверить подключение» shows a result.
3. With local Ollama running (`ollama serve`, a pulled model): ask «Почему диск заполнен?» — text streams, «Стоп» works.
4. Ask «Освободи 5 ГБ безопасно» after a scan → plan card → «Открыть в превью» switches to «Диск», opens «Освободить место» with the «Выбрано ассистентом» banner; nothing was deleted (Trash unchanged).

- [ ] **Step 8: Commit**

```bash
git add SpotlessMac/App SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): assistant tab, settings card, plan staging into preview"
```

---

### Task 16: "Ask assistant" from result rows

**Files:**
- Create: `SpotlessMac/App/AskAssistantAction.swift`
- Modify: `SpotlessMac/App/ContentView.swift`
- Modify: `SpotlessMac/App/StorageRecoveryView.swift`
- Modify: `SpotlessMac/App/UninstallerView.swift`
- Modify: `SpotlessMac/App/DockerCleanupView.swift`

**Interfaces:**
- Consumes: `AssistantFocus` (Task 6), `AssistantSnapshotBuilder.focus(for:…)` (Task 13), `OwnerActivityChecker.check(_:)` (existing), `AssistantViewModel.ask(about:)`.
- Produces: `struct AskAssistantAction { handler; callAsFunction(_:) }`, `EnvironmentValues.askAssistant: AskAssistantAction?`; optional `onAsk: (() -> Void)?` on `StorageRecoveryRow`, `LeftoverRow`, `DockerResourceRow`.

- [ ] **Step 1: Environment action**

`SpotlessMac/App/AskAssistantAction.swift`:
```swift
import SwiftUI

struct AskAssistantAction {
    let handler: @MainActor (AssistantFocus) -> Void

    @MainActor
    func callAsFunction(_ focus: AssistantFocus) {
        handler(focus)
    }
}

private struct AskAssistantKey: EnvironmentKey {
    static var defaultValue: AskAssistantAction? { nil }
}

extension EnvironmentValues {
    var askAssistant: AskAssistantAction? {
        get { self[AskAssistantKey.self] }
        set { self[AskAssistantKey.self] = newValue }
    }
}

// Shared ⓘ button + context menu entry for result rows.
struct AskAssistantButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .help("Спросить ассистента")
        .accessibilityLabel("Спросить ассистента")
    }
}
```

In `ContentView.body`, after `.frame(minWidth: 920, minHeight: 604)` add:
```swift
        .environment(\.askAssistant, AskAssistantAction { focus in
            selectedTab = .assistant
            assistant?.ask(about: focus)
        })
```

- [ ] **Step 2: StorageRecoveryView rows**

In `StorageRecoveryView` add `@Environment(\.askAssistant) private var askAssistant`. In the `StorageRecoveryRow(...)` call add the argument:
```swift
                                onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in { ask(item, action) } }
```
Add to `StorageRecoveryView`:
```swift
    private func ask(_ item: ScanItem, _ action: AskAssistantAction) {
        dismiss()
        Task {
            let activity = await OwnerActivityChecker.check(item)
            action(AssistantSnapshotBuilder.focus(for: item, ownerActivity: activity))
        }
    }
```
In `StorageRecoveryRow` add `var onAsk: (() -> Void)? = nil` after `let onReveal: () -> Void`; insert before `Button(action: onReveal)`:
```swift
            if let onAsk { AskAssistantButton(action: onAsk) }
```
and append after `.help(item.path.path(percentEncoded: false))`:
```swift
        .contextMenu {
            if let onAsk { Button("Спросить ассистента", systemImage: "sparkles", action: onAsk) }
        }
```

- [ ] **Step 3: Uninstaller leftovers**

In `UninstallerView` add `@Environment(\.askAssistant) private var askAssistant`. Change the `LeftoverRow(...)` call to:
```swift
                            LeftoverRow(
                                item: item,
                                isFlagged: item.size >= UninstallViewModel.largeLeftoverThreshold,
                                onToggle: { viewModel.toggleSelection(item) },
                                onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in
                                    { action(AssistantSnapshotBuilder.focus(for: item, appName: viewModel.selectedApp?.name)) }
                                }
                            )
```
In `LeftoverRow` add `var onAsk: (() -> Void)? = nil` after `let onToggle: () -> Void`; insert before the size `Text(item.formattedSize)`:
```swift
            if let onAsk { AskAssistantButton(action: onAsk) }
```
and after `.onTapGesture(perform: onToggle)`:
```swift
        .contextMenu {
            if let onAsk { Button("Спросить ассистента", systemImage: "sparkles", action: onAsk) }
        }
```

- [ ] **Step 4: Docker resources**

In `DockerCleanupView` add `@Environment(\.askAssistant) private var askAssistant`. Change the `DockerResourceRow(...)` call to:
```swift
                        DockerResourceRow(
                            resource: resource,
                            disabled: viewModel.isScanning || viewModel.isDeleting,
                            onToggle: { viewModel.toggle(resource) },
                            onAsk: askAssistant.map { (action: AskAssistantAction) -> () -> Void in
                                { action(AssistantSnapshotBuilder.focus(for: resource)) }
                            }
                        )
```
In `DockerResourceRow` add `var onAsk: (() -> Void)? = nil` after `let onToggle: () -> Void`; insert before `Text(resource.formattedSize)`:
```swift
            if let onAsk { AskAssistantButton(action: onAsk) }
```
and after the `.onTapGesture { … }` block:
```swift
        .contextMenu {
            if let onAsk { Button("Спросить ассистента", systemImage: "sparkles", action: onAsk) }
        }
```

- [ ] **Step 5: Register, build, test**

Run:
```bash
scripts/xcodeproj-add.py app App SpotlessMac/App/AskAssistantAction.swift
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
scripts/test.sh
```
Expected: build succeeds; suite green (minus pre-existing failures).

Manual: «Диск» → «Освободить место» → ⓘ on DerivedData closes the sheet, opens «Помощь» and streams an answer about that item. Same from an uninstaller leftover and a Docker image.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/App SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(assistant): ask the assistant from result rows"
```

---

### Task 17: Final verification

**Files:**
- Modify: `docs/superpowers/specs/2026-10-02-cleanup-assistant-design.md` (only if implementation deviated)

- [ ] **Step 1: Full test suite and both builds**

Run:
```bash
scripts/test.sh
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -configuration Release -destination "platform=macOS" -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: .*(Sendable|actor)|BUILD (SUCCEEDED|FAILED)"
```
Expected: `** TEST SUCCEEDED **` (or only the pre-existing failures from Task 1), Release `** BUILD SUCCEEDED **`, no new concurrency warnings in Assistant files.

- [ ] **Step 2: Safety re-check**

Run:
```bash
grep -rnE "trashItem|removeItem|moveItem|unlink\(|Process\(|NSWorkspace|ScanEngine|ScanViewModel" SpotlessMac/Assistant || echo "clean"
grep -rn "trashItem" SpotlessMac | grep -v ScanEngine/ || echo "trashItem only in ScanEngine"
```
Expected: `clean`; `trashItem` only under `SpotlessMac/ScanEngine/` (plus any pre-existing uninstall/docker paths that were already there before this branch — compare with `git grep trashItem main`).

- [ ] **Step 3: Manual end-to-end checklist** (`./scripts/install-local-debug.sh`)

1. Ollama Cloud (`gpt-oss:20b`, real token): first send shows the disclosure sheet; «Понятно» sends; answer streams. Confirm no full home path or project names appear in the request with a proxy-free check: temporarily set the URL to `http://localhost:9999` with `nc -l 9999` in a terminal and inspect the request body, then restore the URL.
2. Local Ollama with a tool-capable model (e.g. `qwen3:8b`): «Освободи 5 ГБ безопасно» → status line «Смотрю список найденного…» → plan card.
3. Local Ollama with a model without tools (e.g. `gemma:2b`) in «Авто»: answer arrives, plan card comes from the text block; «Проверить подключение» reports «инструменты не поддерживаются».
4. LM Studio (OpenAI-compatible, `http://localhost:1234`): chat works without a token.
5. Wrong token → «Неверный токен…» with «Настройки» button; Ollama stopped → «Не удалось подключиться к localhost:11434…».
6. Quit and relaunch → last conversation restored; «Новый диалог» clears it.
7. Plan → «Открыть в превью» → banner; Trash contents unchanged until the user presses the existing delete button and confirms.

- [ ] **Step 4: Sync the spec if needed and commit**

If any behavior differs from the spec, update the spec section in place (one line per deviation), then:
```bash
git add docs/superpowers/specs/2026-10-02-cleanup-assistant-design.md
git commit -m "docs: align assistant spec with implementation"
```
