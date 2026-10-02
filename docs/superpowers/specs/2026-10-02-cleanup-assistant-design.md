# Cleanup Assistant — Design

Date: 2026-10-02
Status: implemented on `feature/ai-assistant`; aligned with the implementation (Task 17)

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
| D3 | Privacy: whenever data leaves this Mac paths are **redacted** and a one-time cloud disclosure precedes the first send. "Leaves this Mac" is `AssistantSettings.sendsDataOffDevice`: Ollama Cloud always; `.ollamaLocal` and OpenAI-compatible only when the `baseURL` host is not loopback (`localhost`, `127.0.0.1`, `::1`). A loopback server (local Ollama, LM Studio) receives full paths. |
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
| `LLMError` | `missingAPIKey`, `unauthorized`, `modelNotFound`, `rateLimited`, `toolsUnsupported`, `connectionRefused`, `timedOut`, `httpStatus(code, body)`, `decodingFailed`, `invalidURL`, `streamInterrupted`; each maps to a Russian user message. |
| `SystemSnapshot` | `Sendable` value type: volume overview, FDA status, scan timestamp, per-category totals, up to 150 largest `ScanItem`s with short IDs (`c1…`), Docker summary, leftovers summary, last `CleanupReport`, read-only memory info (pressure, used/physical, swap, top-5 user apps). Contains no references to live objects. |
| `AssistantSnapshotBuilder` (planned as `SnapshotBuilder`) | `@MainActor`; builds a `SystemSnapshot` from `ScanViewModel`, `DockerCleanupViewModel`, `UninstallViewModel`, `StorageAnalysisViewModel` (read-only access). Lives **outside** `Assistant/` (in `ViewModels/`) since it touches app view models. |
| `SnapshotRenderer` | Renders snapshot as Russian text for a system message; trims item list to a ~8k-token budget (≈4 chars/token). |
| `PathRedactor` | Off-device redaction (see §6). Keeps an in-memory alias map per conversation; `redactText` is alias-aware, so restored history is re-redacted before every send. |
| `AssistantTool` | Closed `enum`: `listItems(category:minBytes:olderThanDays:limit:)` (`limit` 1–200, default 50), `itemDetails(id:)`, `proposePlan(ids:filters:reason:)`. JSON schemas for both providers. `list_items` arguments are validated strictly: a wrong-typed `limit` / `minBytes` / `olderThanDays` (a boolean counts as wrong-typed), a negative `minBytes` / `olderThanDays`, or a non-string or unknown `category` is an error instead of a silently dropped filter (explicit JSON `null` = not provided). |
| `AssistantToolbox` | Executes tools against an immutable `SystemSnapshot` only. Unknown tool names / invalid args → error result returned to the model + `Logger` warning. A `propose_plan` that resolves to nothing returns «План пуст…» (no card is shown); a non-empty result reports the skipped groups and the manual-review count so the model can describe them. |
| `PlanParser` | Fallback: extracts and strips a fenced ` ```spotless-plan ` JSON block from assistant text. |
| `PlanResolver` | Resolves IDs + filters (`category` required, optional `olderThanDays`, `minBytes`; age measured from `snapshot.takenAt`) against the snapshot. Drops unknown IDs and items with disposition `inspectOnly` or `personalData`. Only batch-cleanable items (`ScanCategory.isBatchCleanable`: user caches, developer caches, logs) are selectable; other deletable items go to `manualReview` (deleted one-by-one by the user). Output: `AssistantPlan { itemIDs: [UUID], totalBytes, reason, skipped: [SkippedGroup], manualReview: [String] }`. |
| `ConversationStore` | Saves/loads the last conversation to `~/Library/Application Support/SpotlessMac/assistant-conversation.json`. Corrupt file → empty conversation. |
| `AssistantViewModel` | `@Observable @MainActor`. Messages, streaming state, cancel, tool loop (max 4 rounds), `toolMode = auto` fallback with per-model cache, `newConversation()`, `ask(about:)`, `retry()`, `openPlan(messageID:)` (calls the `stagePlan` dependency). `ask(about:)` is a no-op until the assistant is configured (see §5). `retry()` goes through the same cloud disclosure as `send`. `openPlan` sets `planNotice` and stays put when `stagePlan` reports a stale plan (see §5). |
| Views | `AssistantView` (with the «Что можно улучшить» panel inlined), `AssistantMessageView` (also hosts `AssistantPlanCard` and `CloudDisclosureSheet`), `AssistantMarkdownView` over the pure `AssistantMarkdownBlocks` parser in `Assistant/` (block markdown, ported from wooffoow `SummaryMarkdownView`), `AssistantSettingsCard`, and the `AskAssistantAction` environment value + shared ⓘ button / context menu for rows. |

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

- `AssistantViewModel` is created in `ContentView` as `@State` (an optional, built on first appear) and its `Dependencies` hold **only** these nine members, pinned by `AssistantIsolationTests`:
  - `settingsStore` / `keyStore` / `makeClient`
  - `snapshot: @MainActor () -> SystemSnapshot`
  - `stagePlan: @MainActor (AssistantPlan) -> Bool` — `false` means nothing could be staged (stale plan)
  - `conversationStore`, `homePath`
  - `refreshContext: @MainActor () async -> Void` (memory sample, see §8a), `now`
- `UninstallViewModel` is hoisted from `UninstallerView` into `ContentView` `@State` so the snapshot can read leftovers and they survive tab switches. Volume capacity is read directly from `/` resource values (no hoisting of `StorageAnalysisViewModel`).
- `ScanViewModel` gains `stageSelection(_ ids: Set<UUID>) -> AssistantStaging?`: for batch-cleanable items sets `isSelected = ids.contains(id)`, records `assistantStaging` (count, bytes) for the preview banner and sets `recoveryPreviewRequested` so `DiskOverviewView` opens the sheet. It returns `nil` and changes nothing when none of the IDs matches a batch-cleanable item (item IDs change on every scan, so a plan is stale after a rescan or restart). Also `lastScanAt`. It never deletes.

## 4. No-delete guarantee (non-negotiable)

1. **Capability isolation.** Code under `SpotlessMac/Assistant/` holds no reference to `ScanEngine`, `ScanViewModel`, `DockerCleanupViewModel`, `DockerClient`, `UninstallViewModel`, `UninstallEngine`, or the Memory section's quit flow (`MemoryViewModel`, `AppTerminator`). Its only outward effect is the `stagePlan` closure, which only toggles selection.
2. **Closed tool set.** `AssistantTool` has exactly three cases, all operating on in-memory snapshot data. No filesystem, process, or network access. Any other tool name from the model is rejected. Raw paths are never accepted as arguments — only snapshot IDs.
3. **Source guard test.** `AssistantIsolationTests` scans every regular file under `SpotlessMac/Assistant/`, recursively and with any extension, and fails on any of: `trashItem`, `removeItem`, `moveItem`, `copyItem`, `unlink(`, `FileManager`, `Process(`, `NSWorkspace`, `ScanEngine`, `ScanViewModel`, `DockerCleanupViewModel`, `DockerClient`, `DockerCommandRunner`, `UninstallViewModel`, `UninstallEngine`, `deleteWithProgress`, `cleanCache`, `URL(fileURLWithPath`, plus the Memory section's quit path: `MemoryViewModel`, `AppTerminator`, `NSRunningApplication`, `terminate(`, `forceTerminate`, `kill(`, and further process-spawn / file-mutation tokens: `posix_spawn`, `NSAppleScript`, `popen(`, `rmdir(`, `FileHandle`, `replaceItem`, `createFile(`, `Darwin.system`, `NSTask` (a bare `system(` is left out: it collides with `AssistantPrompt.system(toolsEnabled:)`). Single allowlisted exception: `ConversationStore.swift` may use `FileManager`, and only its `urls(for:in:)`, `createDirectory`, `homeDirectoryForCurrentUser` members; a second test requires every mention to be a direct `FileManager.default.<member>` call. Further tests pin `AssistantViewModel.Dependencies` to its nine approved members and the tool set to exactly `list_items` / `item_details` / `propose_plan`. (`KeychainStore.delete` for the API key is allowed — it touches only the Keychain item.) Views live in `SpotlessMac/App/`; row focus builders live in `SpotlessMac/ViewModels/`.
4. **User-only deletion.** Staged items show a banner in the «Освободить место» sheet: «Выбрано ассистентом: N элементов, X. Проверьте список перед удалением». Deletion requires the user to press the existing «Очистить выбранное · X» button and confirm «Переместить в Корзину», and still passes `SafetyRules.isSafe`. No auto-confirm, no "delete now" from chat, no shortcut.

CLAUDE.md "Safety rules" gains rule 6: *Assistant never deletes or quits — the Assistant module has no access to deletion or process-quit APIs; enforced by `AssistantIsolationTests`.*

## 5. UI

### Assistant tab
- `AppTab.assistant` (raw value «Ассистент»), rail icon `sparkles`, short label «Помощь»; included in `mainTabs` (and therefore in the launch-tab picker).
- Header in house style (48pt gradient tile, 23pt title, subtitle «провайдер · модель»), button «Новый диалог».
- **«Что можно улучшить»** panel, computed locally from the snapshot (no LLM call): large developer caches, Docker reclaimable space, leftovers of removed apps, stale scan (> 3 days), missing FDA, memory pressure warning/critical or swap ≥ 1 GB. Tapping a row sends a prepared question. No scan yet → «Запустить сканирование» button (calls existing scan via a closure in `ContentView`, not from `Assistant/`).
- Suggestion chips: «Почему диск заполнен?», «Освободи 20 ГБ безопасно», «Что можно удалить из Docker?», «Хватит ли места на обновление macOS?».
- Messages: a message that is still streaming renders as plain text (re-parsing markdown on every token is wasted work); block markdown is applied once it completes. Links in model output are never clickable (rendered as plain text). Status line during tool calls («Смотрю список найденного…», «Изучаю элемент…», «Составляю план…»), caption «модель · время».
- Plan card: «План: N элементов · X», reason, «Пропущено: …», buttons «Открыть в превью» / «Отклонить». A stale plan (no item of the plan matches the current scan after a rescan or app restart) is refused: the preview is not opened, the current selection is kept and an orange notice «Список найденного изменился — попросите ассистента составить план заново.» appears above the composer until the next send or «Новый диалог».
- Input: Enter sends, ⌥Enter newline (native multi-line `TextField`), «Стоп» during streaming.
- Empty states: not configured → «Подключите модель» + button to Settings; errors → message + hint + «Повторить» where relevant.
- Cloud disclosure (once, before the first send off this Mac, i.e. when `sendsDataOffDevice`; flag `assistantCloudDisclosureAccepted` in UserDefaults). «Повторить» goes through it too, because the provider may have been switched to a cloud one since the failure; the failed message stays until the user decides. What is sent (categories, sizes, dates, redacted paths) and what is not (file contents). Buttons «Понятно» / «Использовать локальную Ollama».

### "Ask assistant" entry points
Context menu item + ⓘ button on `StorageRecoveryRow`, leftover rows in `UninstallerView`, resource rows in `DockerCleanupView`. Switches to the Assistant tab and sends «Что это и можно ли удалить?» with a full item card (path, policy, reason, owner, owner running state via `OwnerActivityChecker` computed outside `Assistant/` and passed in). The tab switch is unconditional, but `ask(about:)` does nothing until the assistant is configured: no message, no queued exchange and no disclosure sheet. The user just lands on «Подключите модель».

### Settings card «АССИСТЕНТ»
Built with existing `settingsCard(_:icon:iconColor:content:)`:
- Provider segmented control; switching applies preset URL/model. Switching to a different provider clears the token field (a key typed for one endpoint must never reach another); switching back to the saved provider restores the saved key.
- URL field; token `SecureField` (hidden for local Ollama, optional for OpenAI-compatible) with hint «Хранится в Keychain».
- Model picker populated from `listModels()` with refresh button, plus free-text entry.
- Tool mode «Авто / Вкл / Выкл» with explanation; timeout stepper.
- «Проверить подключение»: short real request; shows «✓ Ответила <model> · инструменты поддерживаются/не поддерживаются» or the mapped error. Result seeds the per-model tool-support cache. Success requires a stream that ends with an explicit `.done`: a cancelled check reports «Проверка отменена» and a truncated stream fails with `streamInterrupted` instead of passing.
- «Сохранить» / «Сбросить». Empty token on save deletes the Keychain entry.

## 6. Prompt and context

**System prompt** (Russian constant): role; can only recommend and propose plans, never delete; everything goes to Trash; never recommend `/System`, swap, `personalData`, `inspectOnly`; say «не знаю» for items absent from data; never invent paths; glossary of dispositions and categories (from `CleanupDisposition.label`, `ScanCategory.cleanupReason`); answer format: verdict (безопасно / осторожно / не трогать) + what happens after removal; propose a plan only when asked or clearly beneficial. Fallback mode appends the exact `spotless-plan` schema and an example:

```spotless-plan
{"items": ["c12", "c40"], "filters": [{"category": "developer_caches", "olderThanDays": 30}], "reason": "..."}
```

**Context** — a separate system message rebuilt on every send:
```
Диск: «Macintosh HD», 494 ГБ, свободно 31 ГБ (6%).
Сканирование: 2026-10-02 14:10, FDA: есть.
Категории: developer_caches 12,4 ГБ (rebuildable, 312 эл.); ...
Крупные элементы:
c1 | ~/Library/Developer/Xcode/DerivedData | 9,8 ГБ | developer_caches | rebuildable | изм. 2026-08-11 | владелец: Xcode
Docker: виртуальный диск 48 ГБ, можно освободить 6 ГБ; образы 12, тома 3 (2 — dataLoss).
Остатки приложений: 3 (exact: 2, nameOnly: 1), 1,2 ГБ.
Последняя очистка: в корзину 3,4 ГБ, наблюдаемый прирост 3,1 ГБ.
Память: давление высокое, занято 15 ГБ из 16 ГБ, своп 4 ГБ. Больше всего памяти занимают: Xcode — 6 ГБ, Google Chrome — 3 ГБ.
```
- ≤ 150 items, trimmed further above ~8k tokens; with tools the model can fetch more via `list_items`.
- Category ids in the context, in tool arguments and in the `spotless-plan` block are `ScanCategory.rawValue` (snake_case, e.g. `developer_caches`). The block above is illustrative; the exact line format lives in `SnapshotRenderer`.
- History: last 20 messages; only the current snapshot is sent, never old ones.

**Redaction (only when `sendsDataOffDevice`, see D3):**
- `/Users/<name>` → `~`.
- First path component under `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Projects`, `~/MyProjects`, `~/Developer`, `~/src`, `~/code`, `~/Movies`, `~/Music`, `~/Pictures` → `<папка-N>`, numbering stable within a conversation.
- Known non-personal cache paths (`~/Library/Caches/...`, `DerivedData`, `~/.cache/huggingface`, etc.) kept verbatim.
- The computer name is never put into the snapshot; a non-default volume name is replaced with «системный диск».
- Model output is shown as-is; `<папка-N>` tokens in it are mapped back to real paths for display using the in-memory map (the map itself is never persisted or sent). The restored text is what gets persisted in the history, so history is re-redacted on every send: `redactText` re-aliases already-registered folder names (with or without a `~/<root>/` prefix) as well as home paths.
- The formatter the view model hands to the renderer and the toolbox redacts home-prefixed paths and also free text (item reasons, tool output, user messages) through `redactText`; a plan's `reason` is restored for display too.

**Tools:**
- `auto`: first request includes `tools`; a "does not support tools" response (Ollama HTTP 400 with that text; OpenAI-compatible equivalent) marks the model as tool-less in an in-memory+UserDefaults cache and the request is retried in fallback mode.
- Max 4 tool rounds per answer, then a final request without `tools`.
- `propose_plan` never applies anything; it produces a plan card, and only when the resolved plan is non-empty (selected items, skipped groups or manual-review lines). An empty plan returns «План пуст…» to the model, a non-empty one reports the skipped groups and manual-review count.

## 7. Error handling

| Situation | User sees |
|---|---|
| 401/403 | «Неверный токен. Проверьте его в Настройки → Ассистент» + button to Settings |
| Connection refused | «Не удалось подключиться к localhost:11434. Если это локальная Ollama — запустите приложение Ollama или `ollama serve`» (host:port of the configured server) |
| 404 model | «Модель не найдена. Выберите другую в настройках» |
| 429 | «Превышен лимит запросов. Попробуйте позже.» |
| Timeout | «Модель не ответила за N с» + hint to raise timeout |
| Stream interrupted | partial text kept, marked «ответ прерван», «Повторить» |
| User cancel | partial text kept, marked «остановлено» |
| Bad plan JSON / unknown IDs | no plan card, or «Пропущено: N неизвестных»; text kept |
| Unknown tool from model | rejected, error returned to the model, `Logger` warning |
| Stale plan («Открыть в превью» after a rescan or restart) | preview not opened, selection kept, notice «Список найденного изменился — попросите ассистента составить план заново.» |

## 8. Testing

XCTest with stubbed `HTTPTransport` and fake `APIKeyStoring`:
`OllamaClientTests`, `OpenAICompatibleClientTests`, `LLMErrorTests`, `SnapshotRendererTests`, `PathRedactorTests`, `AssistantPlanTests` (parser + resolver), `AssistantToolboxTests`, `AssistantMarkdownBlocksTests`, `LLMClientFactoryTests`, `AssistantViewModelTests` (streaming, tool-loop cap, auto fallback + cache, cancel, plan card vs. staging), `ConversationStoreTests`, `AssistantSettingsTests`, `AssistantIsolationTests`, and `AssistantStagingTests` for `ScanViewModel.stageSelection` (selects only existing IDs, never deletes, returns `nil` and changes nothing for a stale plan).

Manual: `scripts/install-local-debug.sh`; Ollama Cloud (`gpt-oss:20b`), local Ollama with a tool-capable model and a tool-less model, LM Studio (OpenAI-compatible); verify a model attempting `delete_file` is refused and logged.

## 8a. Memory context (added after the Memory section landed on main)

- `AssistantMemoryCache` (in `ViewModels/`) takes a `MemoryMonitor().sample()` before every answer (`Dependencies.refreshContext`) and when the Assistant tab appears; the snapshot maps it to `MemoryInfo` (pressure, used/physical, swap, top-5 user apps).
- The assistant may only advise which app to close; quitting stays manual in the «Память» tab. The guard forbids `MemoryViewModel`, `AppTerminator`, `NSRunningApplication`, `terminate(`, `forceTerminate`, `kill(` in `SpotlessMac/Assistant/`.

## 9. Out of scope (v1)

- Plans for Docker resources and app leftovers (explanations only).
- Selecting non-batch items (model caches, project artifacts, large files) — they are listed in the plan card for manual removal.
- Background advice on the Care dashboard.
- Multiple conversations / history list.
- Separate framework target for the Assistant module (stronger compile-time isolation; revisit later).
- Rescans or scope changes driven by the model.
- Quitting apps or processes from the assistant (advice only).
