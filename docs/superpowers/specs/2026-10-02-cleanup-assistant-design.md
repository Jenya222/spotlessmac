# Cleanup Assistant — Design

Date: 2026-10-02
Status: approved in brainstorming, awaiting spec review

## 1. Goal

Add an AI assistant to SpotlessMac that explains what is safe to remove, what is
not, and why, and can propose a cleanup plan built from existing scan results.
The assistant **advises and stages selections only — it can never delete anything.**

Users: SpotlessMac users who want a second opinion before cleaning, especially
on developer caches, Docker, ML model caches and app leftovers.

Success criteria:
- User connects Ollama Cloud (token), local Ollama, or an OpenAI-compatible server
  in Settings, picks a model, and verifies the connection.
- User chats with the assistant in a dedicated tab; the assistant sees the current
  system snapshot (disk, categories, largest items, Docker, leftovers, last cleanup).
- User can ask "What is this? Can I delete it?" from a row in the «Освободить место» list, Uninstaller
  leftovers and Docker.
- The assistant can propose a plan; the user opens it in the normal «Освободить место» preview
  and trashes items themselves.
- No code path exists from the assistant to any deletion API (enforced by tests).

Competitive context: CleanMyMac Smart Insights (per-item explanation, on-device,
no chat, no actions) and Microsoft Copilot PC insights (read-only Q&A). A
scan-aware chat that stages a reviewable plan is not offered by competitors.

## 2. Decisions

| # | Decision |
|---|----------|
| D1 | Capability level: **advise + stage a selection** (no autonomous actions, no rescans). |
| D2 | Providers: **Ollama Cloud, local Ollama, OpenAI-compatible** (two client implementations behind one protocol). |
| D3 | Privacy: for cloud providers paths are **redacted**; local Ollama receives full paths; one-time cloud disclosure before first send. |
| D4 | Entry points: **Assistant tab** + **"Ask assistant"** on rows in the «Освободить место» list (`StorageRecoveryView`), Uninstaller leftovers, Docker. |
| D5 | History: **last conversation persisted** to Application Support (JSON), restored on launch. |
| D6 | Plan mechanism: **hybrid** — native tool calling when the model supports it, fenced `spotless-plan` block otherwise. |
| D7 | No-delete guarantee enforced **architecturally** (capability isolation + closed tool set + source guard test), not by prompt. |

## 3. Architecture

New folder `SpotlessMac/Assistant/`.

| Component | Responsibility |
|---|---|
| `AssistantSettings` | `Codable` struct: `provider` (`ollamaCloud` / `ollamaLocal` / `openAICompatible`), `baseURL`, `model`, `toolMode` (`auto` / `on` / `off`), `timeoutSeconds` (10–300, default 120). Persisted as JSON in UserDefaults key `assistantSettings`. Provider presets: cloud `https://ollama.com`, local `http://localhost:11434`, OpenAI `https://api.openai.com`; default model `gpt-oss:20b` for Ollama providers, empty for OpenAI-compatible. |
| `APIKeyStoring` / `AssistantKeyStore` | Protocol + Keychain implementation over existing `KeychainStore`, account `assistantAPIKey`. Fake in tests. |
| `LLMClient` (protocol) | `func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>`; `func listModels() async throws -> [String]`. `ChatEvent`: `.text(String)`, `.toolCalls([ToolCall])`, `.done`. |
| `OllamaClient` | `POST {base}/api/chat`, `stream: true`, NDJSON lines; `tools` when enabled; `Authorization: Bearer` only when key non-empty. Models from `GET {base}/api/tags`. |
| `OpenAICompatibleClient` | `POST {base}/v1/chat/completions`, `stream: true`, SSE (`data:` / `[DONE]`), accumulates chunked `tool_calls`. Models from `GET {base}/v1/models`. |
| `HTTPTransport` | Injectable protocol over `URLSession.bytes(for:)`; stub in tests. Sets `URLRequest.timeoutInterval` explicitly. |
| `LLMError` | `missingAPIKey`, `unauthorized`, `modelNotFound`, `rateLimited`, `toolsUnsupported`, `connectionRefused`, `timedOut`, `httpStatus(code, body)`, `decodingFailed`, `streamInterrupted`; each maps to a Russian user message. |
| `SystemSnapshot` | `Sendable` value type: volume overview, FDA status, scan timestamp, per-category totals, up to 150 largest `ScanItem`s with short IDs (`c1…`), Docker summary, leftovers summary, last `CleanupReport`. Contains no references to live objects. |
| `SnapshotBuilder` | `@MainActor`; builds a `SystemSnapshot` from `ScanViewModel`, `DockerCleanupViewModel`, `UninstallViewModel`, `StorageAnalysisViewModel` (read-only access). Lives **outside** `Assistant/` (in `ViewModels/`) since it touches app view models. |
| `SnapshotRenderer` | Renders snapshot as Russian text for a system message; trims item list to a ~8k-token budget (≈4 chars/token). |
| `PathRedactor` | Cloud-only redaction (see §6). Keeps an in-memory reverse map per conversation. |
| `AssistantTool` | Closed `enum`: `listItems(category:minBytes:olderThanDays:)`, `itemDetails(id:)`, `proposePlan(ids:filters:reason:)`. JSON schemas for both providers. |
| `AssistantToolbox` | Executes tools against an immutable `SystemSnapshot` only. Unknown tool names / invalid args → error result returned to the model + `Logger` warning. |
| `PlanParser` | Fallback: extracts and strips a fenced ` ```spotless-plan ` JSON block from assistant text. |
| `PlanResolver` | Resolves IDs + filters (`category` required, optional `olderThanDays`, `minBytes`; age measured from `snapshot.takenAt`) against the snapshot. Drops unknown IDs and items with disposition `inspectOnly` or `personalData`. Only batch-cleanable items (`ScanCategory.isBatchCleanable`: user caches, developer caches, logs) are selectable; other deletable items go to `manualReview` (deleted one-by-one by the user). Output: `AssistantPlan { itemIDs: [UUID], totalBytes, reason, skipped: [SkippedGroup], manualReview: [String] }`. |
| `ConversationStore` | Saves/loads the last conversation to `~/Library/Application Support/SpotlessMac/assistant-conversation.json`. Corrupt file → empty conversation. |
| `AssistantViewModel` | `@Observable @MainActor`. Messages, streaming state, cancel, tool loop (max 4 rounds), `toolMode = auto` fallback with per-model cache, `newConversation()`, `ask(about:)`, `stagePlan(_:)`. |
| Views | `AssistantView`, `AssistantMessageView` (block markdown, ported from wooffoow `SummaryMarkdownView`), `AssistantPlanCard`, `AssistantImprovementsPanel`, `AssistantSettingsCard`, `CloudDisclosureSheet`. |

### Data flow

```
AssistantView → AssistantViewModel
  → snapshotProvider() → SystemSnapshot → SnapshotRenderer (+ PathRedactor if cloud)
  → LLMClient.stream → ChatEvent
      .toolCalls → AssistantToolbox (snapshot only) → back to LLMClient (≤ 4 rounds)
      .text      → message (PlanParser strips spotless-plan block in fallback mode)
  → PlanResolver → AssistantPlan → plan card in message
  → user taps "Открыть в превью" → stagePlan(plan) closure
      → ScanViewModel.stageSelection marks isSelected on those batch-cleanable items,
        switches to the «Диск» tab and opens the «Освободить место» sheet (StorageRecoveryView)
      → user reviews the list and presses the existing delete button (existing confirmation, SafetyRules.isSafe)
```

### Wiring

- `AssistantViewModel` is created in `ContentView` as `@State` and receives **only**:
  - `settings` / `keyStore` / `clientFactory`
  - `snapshotProvider: @MainActor () -> SystemSnapshot`
  - `stagePlan: @MainActor (AssistantPlan) -> Void`
  - `conversationStore`
- `UninstallViewModel` is hoisted from `UninstallerView` into `ContentView` `@State` so the snapshot can read leftovers and they survive tab switches. Volume capacity is read directly from `/` resource values (no hoisting of `StorageAnalysisViewModel`).
- `ScanViewModel` gains `stageSelection(_ ids: Set<UUID>) -> AssistantStaging`: for batch-cleanable items sets `isSelected = ids.contains(id)`, records `assistantStaging` (count, bytes) for the preview banner and sets `recoveryPreviewRequested` so `DiskOverviewView` opens the sheet. Also `lastScanAt`. It never deletes.

## 4. No-delete guarantee (non-negotiable)

1. **Capability isolation.** Code under `SpotlessMac/Assistant/` holds no reference to `ScanEngine`, `ScanViewModel`, `DockerCleanupViewModel`, `DockerClient`, `UninstallViewModel`, `UninstallEngine`. Its only outward effect is the `stagePlan` closure, which only toggles selection.
2. **Closed tool set.** `AssistantTool` has exactly three cases, all operating on in-memory snapshot data. No filesystem, process, or network access. Any other tool name from the model is rejected. Raw paths are never accepted as arguments — only snapshot IDs.
3. **Source guard test.** `AssistantIsolationTests` scans `SpotlessMac/Assistant/*.swift` and fails on any of: `trashItem`, `removeItem`, `moveItem`, `copyItem`, `unlink(`, `FileManager`, `Process(`, `NSWorkspace`, `ScanEngine`, `ScanViewModel`, `DockerCleanupViewModel`, `DockerClient`, `DockerCommandRunner`, `UninstallViewModel`, `UninstallEngine`, `deleteWithProgress`, `cleanCache`, `URL(fileURLWithPath`. Single allowlisted exception: `ConversationStore.swift` may use `FileManager`, and only its `urls(for:in:)`, `createDirectory`, `homeDirectoryForCurrentUser` members. (`KeychainStore.delete` for the API key is allowed — it touches only the Keychain item.) Views live in `SpotlessMac/App/`; row focus builders live in `SpotlessMac/ViewModels/`.
4. **User-only deletion.** Staged items show a banner in the «Освободить место» sheet: «Выбрано ассистентом: N элементов, X. Проверьте список перед удалением». Deletion requires the user to press «В корзину» and pass the existing confirmation and `SafetyRules.isSafe`. No auto-confirm, no "delete now" from chat, no shortcut.

CLAUDE.md "Safety rules" gains rule 6: *Assistant never deletes — the Assistant module has no access to deletion APIs; enforced by `AssistantIsolationTests`.*

## 5. UI

### Assistant tab
- `AppTab.assistant` (raw value «Ассистент»), rail icon `sparkles`, short label «Помощь»; included in `mainTabs` (and therefore in the launch-tab picker).
- Header in house style (48pt gradient tile, 23pt title, subtitle «провайдер · модель»), button «Новый диалог».
- **«Что можно улучшить»** panel, computed locally from the snapshot (no LLM call): large developer caches, Docker reclaimable space, leftovers of removed apps, stale scan (> 3 days), missing FDA. Tapping a row sends a prepared question. No scan yet → «Запустить сканирование» button (calls existing scan via a closure in `ContentView`, not from `Assistant/`).
- Suggestion chips: «Почему диск заполнен?», «Освободи 20 ГБ безопасно», «Что можно удалить из Docker?», «Хватит ли места на обновление macOS?».
- Messages: streamed text, block markdown, status line during tool calls («Смотрю кэши разработки…»), caption «модель · время».
- Plan card: «План: N элементов · X», reason, «Пропущено: …», buttons «Открыть в превью» / «Отклонить».
- Input: Enter sends, ⌥Enter newline (native multi-line `TextField`), «Стоп» during streaming.
- Empty states: not configured → «Подключите модель» + button to Settings; errors → message + hint + «Повторить» where relevant.
- Cloud disclosure (once, before first cloud send; flag `assistantCloudDisclosureAccepted` in UserDefaults): what is sent (categories, sizes, dates, redacted paths) and what is not (file contents). Buttons «Понятно» / «Использовать локальную Ollama».

### "Ask assistant" entry points
Context menu item + ⓘ button on `StorageRecoveryRow`, leftover rows in `UninstallerView`, resource rows in `DockerCleanupView`. Switches to the Assistant tab and sends «Что это и можно ли удалить?» with a full item card (path, policy, reason, owner, owner running state via `OwnerActivityChecker` computed outside `Assistant/` and passed in).

### Settings card «АССИСТЕНТ»
Built with existing `settingsCard(_:icon:iconColor:content:)`:
- Provider segmented control; switching applies preset URL/model.
- URL field; token `SecureField` (hidden for local Ollama, optional for OpenAI-compatible) with hint «Хранится в Keychain».
- Model picker populated from `listModels()` with refresh button, plus free-text entry.
- Tool mode «Авто / Вкл / Выкл» with explanation; timeout stepper.
- «Проверить подключение»: short real request; shows «✓ Ответила <model> · инструменты поддерживаются/не поддерживаются» or the mapped error. Result seeds the per-model tool-support cache.
- «Сохранить» / «Сбросить». Empty token on save deletes the Keychain entry.

## 6. Prompt and context

**System prompt** (Russian constant): role; can only recommend and propose plans, never delete; everything goes to Trash; never recommend `/System`, swap, `personalData`, `inspectOnly`; say «не знаю» for items absent from data; never invent paths; glossary of dispositions and categories (from `CleanupDisposition.label`, `ScanCategory.cleanupReason`); answer format: verdict (безопасно / осторожно / не трогать) + what happens after removal; propose a plan only when asked or clearly beneficial. Fallback mode appends the exact `spotless-plan` schema and an example:

```spotless-plan
{"items": ["c12", "c40"], "filters": [{"category": "developerCaches", "olderThanDays": 30}], "reason": "..."}
```

**Context** — a separate system message rebuilt on every send:
```
Диск: «Macintosh HD», 494 ГБ, свободно 31 ГБ (6%).
Сканирование: 2026-10-02 14:10, FDA: есть.
Категории: developerCaches 12,4 ГБ (rebuildable, 312 эл.); ...
Крупные элементы:
c1 | ~/Library/Developer/Xcode/DerivedData | 9,8 ГБ | developerCaches | rebuildable | изм. 2026-08-11 | владелец: Xcode
Docker: виртуальный диск 48 ГБ, можно освободить 6 ГБ; образы 12, тома 3 (2 — dataLoss).
Остатки приложений: 3 (exact: 2, nameOnly: 1), 1,2 ГБ.
Последняя очистка: в корзину 3,4 ГБ, наблюдаемый прирост 3,1 ГБ.
```
- ≤ 150 items, trimmed further above ~8k tokens; with tools the model can fetch more via `list_items`.
- History: last 20 messages; only the current snapshot is sent, never old ones.

**Redaction (cloud providers only):**
- `/Users/<name>` → `~`.
- First path component under `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Projects`, `~/Developer`, `~/src`, `~/code` → `<папка-N>`, numbering stable within a conversation.
- Known non-personal cache paths (`~/Library/Caches/...`, `DerivedData`, `~/.cache/huggingface`, etc.) kept verbatim.
- Computer name and non-default volume names replaced.
- Model output is shown as-is; `<папка-N>` tokens in it are mapped back to real paths for display using the in-memory map (never persisted, never sent).

**Tools:**
- `auto`: first request includes `tools`; a "does not support tools" response (Ollama HTTP 400 with that text; OpenAI-compatible equivalent) marks the model as tool-less in an in-memory+UserDefaults cache and the request is retried in fallback mode.
- Max 4 tool rounds per answer, then a final request without `tools`.
- `propose_plan` never applies anything; it produces a plan card.

## 7. Error handling

| Situation | User sees |
|---|---|
| 401/403 | «Неверный токен. Проверьте его в Настройки → Ассистент» + button to Settings |
| Connection refused (local) | «Ollama не запущена на localhost:11434. Запустите приложение Ollama или `ollama serve`» |
| 404 model | «Модель не найдена. Выберите другую в настройках» |
| 429 | «Превышен лимит запросов Ollama Cloud, попробуйте позже» |
| Timeout | «Модель не ответила за N с» + hint to raise timeout |
| Stream interrupted | partial text kept, marked «ответ прерван», «Повторить» |
| User cancel | partial text kept, marked «остановлено» |
| Bad plan JSON / unknown IDs | no plan card, or «Пропущено: N неизвестных»; text kept |
| Unknown tool from model | rejected, error returned to the model, `Logger` warning |

## 8. Testing

XCTest with stubbed `HTTPTransport` and fake `APIKeyStoring`:
`OllamaClientTests`, `OpenAICompatibleClientTests`, `LLMErrorMappingTests`, `SnapshotRendererTests`, `PathRedactorTests`, `PlanParserTests`, `PlanResolverTests`, `AssistantToolboxTests`, `AssistantViewModelTests` (streaming, tool-loop cap, auto fallback + cache, cancel, plan card vs. staging), `ConversationStoreTests`, `AssistantSettingsTests`, `AssistantIsolationTests`, and a `ScanViewModel.stageSelection` test (selects only existing IDs, never deletes).

Manual: `scripts/install-local-debug.sh`; Ollama Cloud (`gpt-oss:20b`), local Ollama with a tool-capable model and a tool-less model, LM Studio (OpenAI-compatible); verify a model attempting `delete_file` is refused and logged.

## 9. Out of scope (v1)

- Plans for Docker resources and app leftovers (explanations only).
- Selecting non-batch items (model caches, project artifacts, large files) — they are listed in the plan card for manual removal.
- Background advice on the Care dashboard.
- Multiple conversations / history list.
- Separate framework target for the Assistant module (stronger compile-time isolation; revisit later).
- Rescans or scope changes driven by the model.
