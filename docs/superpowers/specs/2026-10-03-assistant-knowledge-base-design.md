# Assistant Knowledge Base — Design

Date: 2026-10-03
Status: implemented; aligned with the plan (Task 13)

## 1. Goal

Give the cleanup assistant curated, offline knowledge about macOS so its answers about
processes, folders, memory, storage and file organization are specific and correct,
not generic model guesses. Today the assistant knows only the system snapshot and three
snapshot tools; with the default `gpt-oss:20b` anything beyond the snapshot is the
model's own (often wrong) recollection.

What the user asked for (2026-10-03): a knowledge base **inside the app**, **tied to the
processes and folders the app observes**, plus a **`lookup_knowledge`** tool. A server-side
knowledge base and web search were discussed and deferred (see §11).

Success criteria:
- The app ships with all 49 wave-1 articles (§9), reviewed, covering the topics users hit most.
- Every scanned item, top memory app and top system process that has an article is annotated
  with that article's id and one-line summary in the context the model receives — no tool
  call needed.
- The model can search the base with `lookup_knowledge` (by id or free text, in Russian).
- Retrieval quality: ≥ 90% of the evaluation queries (§8) return the expected article in the
  top 3.
- The base works identically with every provider, including local Ollama with no internet.
- No new data leaves the Mac: articles are bundled, search runs locally, the only thing
  sent to the LLM is article text, which contains nothing about the user.
- The assistant isolation guarantee (CLAUDE.md rule 6) is unchanged; the guard test is
  extended to the new code.

## 2. Decisions

| # | Decision |
|---|----------|
| K1 | **Bundled**, read-only. Articles ship inside the app bundle; updates arrive with app releases. Remote updates are a later phase (§11). |
| K2 | **Markdown files with a flat front matter**, one article per file, in a resource folder reference. Readable diffs, no build step, no extra toolchain. |
| K3 | **Deterministic binding first**: articles declare the process names, bundle IDs, path patterns and scan categories they describe; the app attaches them to the snapshot. Free-text search is the second channel. |
| K4 | **Pure-Swift search** (BM25 over a few hundred articles, in memory). No SQLite FTS5 (needs `import SQLite3`, outside the assistant's import allowlist) and no embeddings (unnecessary at this size). |
| K5 | **One new tool** `lookup_knowledge(id?, query?)`. Models without tool support get the top hits injected automatically. |
| K6 | **Articles advise GUI steps and SpotlessMac features only** — no terminal commands and no code at all, in line with `AssistantGuard` (the assistant never suggests commands and hides them in answers). Lint-checked (§7). |
| K7 | **The snapshot's own policy wins over an article.** An item marked `personalData` / `inspectOnly` stays protected even if an article calls that kind of folder safe. |
| K8 | Russian only, matching the app. |

## 3. Architecture

| Component | Location | Responsibility |
|---|---|---|
| Articles | `SpotlessMac/Resources/Knowledge/*.md` (blue folder reference, copied to `Contents/Resources/Knowledge/`) | Content. Not under `Assistant/`, so prose never trips the isolation token scan. |
| `KnowledgeArticle` | `Assistant/KnowledgeArticle.swift` | `Sendable` value: `id`, `kind`, `title`, `summary`, `verdict`, `aliases`, `keywords`, `processes`, `bundles`, `paths`, `categories`, `related`, `macOS`, `reviewed`, `sources`, `body`. |
| `KnowledgeParser` | `Assistant/KnowledgeParser.swift` | Parses one file: front matter (§4) + Markdown body. Throws a typed error naming the file and field. |
| `KnowledgeBase` | `Assistant/KnowledgeBase.swift` | Immutable set of articles + lookup by id + `static func loadBundled(from bundle: Bundle) -> KnowledgeBase` (uses `Bundle.urls(forResourcesWithExtension:subdirectory:)` and `String(contentsOf:)` — neither is on the forbidden list). An article that fails to parse is skipped and logged; the rest load. |
| `KnowledgeMatcher` | `Assistant/KnowledgeMatcher.swift` | Binds snapshot entities to articles (§5). Pure function of `(SystemSnapshot, KnowledgeBase, homePath)`. |
| `KnowledgeSearch` | `Assistant/KnowledgeSearch.swift` | Tokenizer + BM25 index built once per `KnowledgeBase`; `search(_ query: String, limit: Int) -> [KnowledgeHit]`. |
| `AssistantTool.lookupKnowledge` | `AssistantTool.swift`, `AssistantToolbox.swift` | New tool case, schema, parsing and execution (§6). |
| Snapshot extensions | `SystemSnapshot.swift`, `ViewModels/AssistantSnapshotBuilder.swift` | Memory info gains bundle IDs and top system/other processes (§5.1). |
| Rendering | `SnapshotRenderer.swift` | Trailing «справка» column on item lines + a «Справка по найденному» section (§5.3). |
| Prompt | `AssistantPrompt.swift` | Rules for using the base (§6.3). |
| Wiring | `AssistantViewModel.Dependencies` | New `knowledge: KnowledgeBase`; the app passes `KnowledgeBase.loadBundled(from: .main)` loaded once at launch, tests pass fixtures. |

Code lives under `Assistant/` on purpose: the isolation test then covers it automatically,
and it uses only `Foundation` and `os`.

Data flow:

```
Resources/Knowledge/*.md ──load once──▶ KnowledgeBase ──▶ AssistantViewModel.deps.knowledge
                                                              │
SystemSnapshot ──▶ KnowledgeMatcher ──▶ annotations ──▶ SnapshotRenderer ──▶ system message
model tool call lookup_knowledge ──▶ KnowledgeSearch / by id ──▶ tool result
tools off: last user message ──▶ KnowledgeSearch top 2 ──▶ extra system message
```

## 4. Article format

File name = `<id>.md`. Front matter is a strict subset of YAML: one `key: value` per line,
lists only as inline `[a, b]`, strings may be double-quoted, no nesting, no multi-line
values. Unknown keys are an error (catches typos). Body: Markdown with fixed `##` sections.

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | `<kind-prefix>.<slug>`, ASCII, matches the file name. Prefixes: `proc.`, `app.`, `path.`, `guide.`. |
| `kind` | yes | `process` · `app` · `path` · `guide` |
| `title` | yes | Human title, Russian. |
| `summary` | yes | One line, ≤ 160 characters. Shown in auto-annotation. |
| `verdict` | yes | `safe` («безопасно»), `caution` («осторожно»), `keep` («не трогать»), `info` (guides). For processes/apps it is about quitting; for paths, about deleting. |
| `aliases` | no | Other names users type: `[спотлайт, индексация]`. |
| `keywords` | no | Extra search terms. |
| `processes` | no | Exact process names: `[mds_stores, mdworker, mdworker_shared]`. |
| `bundles` | no | Bundle IDs: `[com.google.Chrome]`. |
| `paths` | no | Path patterns (§5.2): `[~/Library/Developer/Xcode/DerivedData]`. |
| `categories` | no | `ScanCategory` raw values this article is the fallback for. |
| `related` | no | Article ids; validated to exist. |
| `macOS` | no | Version range the UI steps were checked on: `14-26`. |
| `reviewed` | yes | `YYYY-MM-DD` of the last human review. |
| `sources` | yes for non-guides | URLs (Apple Support, Apple Developer docs, man pages, vendor docs). |

Body sections, in this order (absent sections omitted; `Что это` and `Что делать` required):
`## Что это`, `## Норма`, `## Почему растёт`, `## Что делать`, `## Чего не делать`.
Body length 400–2,500 characters; the tool result caps a single article at 3,000.

Example (`proc.spotlight-indexing.md`). Illustrative: its wording, menu names and source URL are verified like any other article during content review.

```markdown
---
id: proc.spotlight-indexing
kind: process
title: Spotlight индексирует диск (mds, mds_stores, mdworker)
summary: Индексация Spotlight; после обновления macOS или переноса данных может часами грузить процессор — это нормально.
verdict: keep
aliases: [спотлайт, индексация, поиск]
processes: [mds, mds_stores, mdworker, mdworker_shared, corespotlightd]
related: [guide.slow-after-update, guide.spotlight-exclude]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://support.apple.com/guide/mac-help/search-with-spotlight-mchlp1008/mac, man:mdutil]
---
## Что это
Системные процессы поиска Spotlight: mds управляет индексом, mds_stores хранит его,
mdworker читают содержимое файлов.

## Норма
В покое почти не нагружают процессор. После обновления macOS, переноса данных или
подключения большого диска индексация может идти несколько часов.

## Что делать
Оставьте Mac включённым и подключённым к питанию — индексация закончится сама.
Если папка не нужна в поиске (например, архив проектов), исключите её в настройках
Spotlight, раздел конфиденциальности.

## Чего не делать
Не завершайте эти процессы принудительно: индексация начнётся заново.
```

## 5. Binding articles to the snapshot

### 5.1 Snapshot additions

- `MemoryAppInfo` gains `bundleID: String?` (from `RunningAppInfo.bundleIdentifier` of the group's bundle).
- `MemoryInfo` gains `topProcesses: [MemoryProcessInfo]` — up to 8 largest processes from the
  `.system` and `.other` groups (`name`, `bytes`), so `WindowServer`, `kernel_task`,
  `mds_stores`, `node`, `python3` become visible. Built in `AssistantSnapshotBuilder` (outside
  `Assistant/`, as today). Names from `.other` groups go through `formatPath` when rendered,
  like any user-derived text.

### 5.2 Matching rules

- **Items** (`SnapshotItem.path`, the real path, before redaction): a pattern matches if the
  item is the pattern's path or lies inside it, compared by path components. `~` = home,
  `*` = exactly one component of any name. An item that is an *ancestor* of a pattern does
  not match it. Most specific match wins (most components; literal beats `*`). No path match →
  the article listing the item's `ScanCategory` in `categories`. No match → none.
- **Apps**: `bundleID` in `bundles`, else display name equal (case-insensitive) to the title
  or an alias.
- **Processes**: exact name in `processes`. (Chromium/Electron helpers never reach this rule: the
  memory grouper already folds them into their app, which matches by bundle ID.)
- Matching runs on unredacted data inside the assistant; only article ids and article text,
  never the matched path, are added to what the model sees.

### 5.3 Rendering

- Item lines get a trailing column `справка` with the article id or `—`; the header names the column.
- Memory lines append `[id]` after each matched app/process.
- A section after the snapshot body: `Справка SpotlessMac по найденному (id — кратко):` listing
  each matched article once, `id — verdict — summary`, ordered by the bytes they cover, capped at
  12 entries and 2,500 characters (separate from the existing 32,000-character snapshot budget).

## 6. Retrieval

### 6.1 `lookup_knowledge`

Schema: `{ "id": string?, "query": string? }`, at least one required (strict parsing like
`list_items`: wrong types are errors, `null` = absent).

- `id` → the article: title, verdict, summary, body (≤ 3,000 chars), `related` ids.
  Unknown id → «Статья <id> не найдена.» plus the 3 closest titles.
- `query` → up to 3 hits; each with id, title, verdict, summary and body, total ≤ 6,000 chars.
  No hits → «В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет.»
- Status line while running: «Читаю справку…».

### 6.2 Search

- Normalization: lowercase, `ё`→`е`, split on non-letters/digits; underscores and dots split
  too, while the raw token is kept (`mds_stores` indexes `mds_stores`, `mds`, `stores`).
- Light stemming: Cyrillic tokens longer than 5 characters are cut to 5 (`индексация`,
  `индексирует` → `индек`); Latin tokens are kept whole. Tuned against the evaluation set, not
  hard-coded forever.
- BM25 (k1 = 1.2, b = 0.75) with field weights: title ×3, aliases/keywords/processes/bundles ×2,
  summary ×1.5, body ×1. A query token that equals a process name or bundle ID gets an exact-match
  boost so «что за mds_stores» always ranks `proc.spotlight-indexing` first.
- Index is built once at load; at ≤ 1,000 articles it costs milliseconds.

### 6.3 Prompt and tools-off mode

`AssistantPrompt.base` gains:
- «Справка SpotlessMac — проверенные статьи. Вопросы о процессах, папках, памяти, настройках
  macOS и организации файлов сначала проверяй по справке (`lookup_knowledge` или раздел
  «Справка по найденному»). Если справка расходится с твоими знаниями — следуй справке.»
- «Политика элемента в снимке главнее справки.»
- «Не придумывай пути в Системных настройках и команды Терминала, которых нет в справке. Если
  справки нет — скажи, что точных данных нет.»
- Answers may name the article title they rely on.

`toolsGuide` lists `lookup_knowledge`. Unknown-tool error text lists all four tools.

Tools-off mode (`fallbackPlanGuide`): before each request the view model searches the last
user message and injects the top 2 hits (≤ 4,000 chars) as one more system message,
`Справка по вопросу:`. With tools on this injection is skipped.

## 7. Content safety

A corpus test (§8) lints every article:
- **Forbidden in body** (whole words, case-insensitive, anywhere in the text): `sudo`, `rm`, `kill`,
  `killall`, `pkill`, `launchctl unload`, `launchctl bootout`, `launchctl remove`, `defaults write`,
  `defaults delete`, `csrutil`, `purge`, `diskutil erase`, `tmutil delete`. The list lives in the
  test and grows as needed; authors phrase around these words (e.g. «команды очистки памяти»).
- **No code or commands**: no fenced code blocks, and no body line or inline code span that
  `AssistantGuard.looksLikeCommand` recognizes as a terminal command.
- A `path.` article with `verdict: safe` must not match any root that `SafetyRules` forbids or
  treats as personal (`/System`, `/private/var/vm`, Photos library, `~/Library/Mobile Documents`,
  `~/Library/Messages`, iPhone backups…). Checked by running the matcher against those roots.
- Articles refer to SpotlessMac features by their UI names (tabs «Уход», «Программы», «Диск» with
  «Освободить место», «Память», «Docker»), never promise that the assistant itself will act. The
  tab «Чистка» only shows the progress of a running cleanup, so articles never send the user there
  to clean anything.
- Tool output (including `lookup_knowledge`) stays fenced by `AssistantGuard` like all tool output; the
  tools-off reference is bundled, trusted text and goes as its own unfenced system message. The guard's
  topic rule is widened to processes, performance and file organization so these questions are not refused.

## 8. Testing

| Test | Covers |
|---|---|
| `KnowledgeParserTests` | Valid file; missing required field; unknown key; malformed list; id/file-name mismatch; summary > 160; missing required section. |
| `KnowledgeCorpusTests` | Loads the real bundled folder (via `#filePath`): every file parses; ids unique; `related` ids exist; every `ScanCategory` has a fallback article; `reviewed` set; sources present; lint rules from §7. |
| `KnowledgeMatcherTests` | Pattern semantics (`~`, `*`, inside vs ancestor, specificity), category fallback, bundle/name/alias app matching, process names, no match. |
| `KnowledgeSearchTests` | Tokenizer/stemming; exact process-name boost; **evaluation set**: `SpotlessMacTests/Fixtures/knowledge-eval.json`, ~40 real Russian questions → expected id; asserts ≥ 90% in top 3 and prints misses. |
| `AssistantToolboxTests` | `lookup_knowledge` by id, by query, both absent, wrong types, unknown id, no hits, size caps. |
| `SnapshotRendererTests` | `справка` column, memory annotations, section ordering and 2,500-char cap, redaction still applied to `.other` process names. |
| `AssistantViewModelTests` | Tools-off injection of top hits; no injection with tools on. |
| `AssistantIsolationTests` | Unchanged token list; file count floor raised to cover the new files. |

Manual: extend `2026-10-02-cleanup-assistant-manual-checklist.md` with ~15 questions
(«что за kernel_task», «почему Системные данные 80 ГБ», «как разобрать Загрузки»…) answered
with and without the base, checking that answers cite the base and contain no invented settings paths.

## 9. Topics

Wave 1 (P1) ships with the feature; wave 2 (P2) follows as content-only changes.

### Processes and apps

| id | Title | Wave |
|---|---|---|
| `proc.kernel-task` | kernel_task: ядро и охлаждение | P1 |
| `proc.windowserver` | WindowServer: вывод изображения на экраны | P1 |
| `proc.spotlight-indexing` | Spotlight индексирует диск (mds, mds_stores, mdworker) | P1 |
| `proc.photos-analysis` | Анализ медиатеки Фото (photoanalysisd, mediaanalysisd, photolibraryd) | P1 |
| `proc.icloud-sync` | Синхронизация iCloud (bird, cloudd, fileproviderd) | P1 |
| `proc.backupd` | Time Machine делает резервную копию (backupd) | P1 |
| `proc.software-update` | Загрузка обновлений macOS (softwareupdated, nsurlsessiond) | P1 |
| `proc.security-scan` | Проверка безопасности (XProtect, syspolicyd, trustd) | P2 |
| `proc.crash-reporting` | ReportCrash и spindump после сбоев | P2 |
| `proc.launchd` | launchd — первый процесс системы | P2 |
| `proc.webkit` | Safari и процессы WebKit (Safari Web Content) | P1 |
| `proc.virtualization` | Виртуальные машины (com.apple.Virtualization.VirtualMachine) | P1 |
| `proc.dev-runtimes` | node, python, java: запущенные скрипты и серверы разработки | P1 |
| `proc.sourcekit` | Xcode: SourceKitService, индексатор, симуляторы | P2 |
| `proc.coreaudiod` | coreaudiod: звук | P2 |
| `app.chrome` | Google Chrome: вкладки, расширения, экономия памяти | P1 |
| `app.electron` | Electron-приложения (Slack, Discord, Teams, VS Code, Cursor) | P1 |
| `app.docker` | Docker Desktop: память и диск виртуальной машины | P1 |
| `app.telegram` | Telegram: кэш медиа и его лимит | P1 |
| `app.xcode` | Xcode: что занимает место и память | P1 |
| `app.firefox` | Firefox | P2 |
| `app.zoom` | Zoom | P2 |
| `app.adobe-cc` | Adobe Creative Cloud и фоновые службы | P2 |
| `app.microsoft-office` | Microsoft Office и AutoUpdate | P2 |
| `app.ollama-lmstudio` | Ollama и LM Studio: модели в памяти | P2 |

### Paths

| id | Title | Verdict | Wave |
|---|---|---|---|
| `path.user-caches` | ~/Library/Caches: кэши программ | safe | P1 |
| `path.logs` | Журналы и отчёты о сбоях | safe | P1 |
| `path.xcode-deriveddata` | Xcode DerivedData | safe | P1 |
| `path.xcode-device-support` | iOS DeviceSupport | safe | P1 |
| `path.coresimulator` | Симуляторы Xcode (CoreSimulator) | caution | P1 |
| `path.xcode-archives` | Архивы Xcode | caution | P2 |
| `path.iphone-backups` | Резервные копии iPhone и iPad | keep | P1 |
| `path.mobile-documents` | iCloud Drive (Mobile Documents) | keep | P1 |
| `path.photos-library` | Медиатека Фото | keep | P1 |
| `path.messages-attachments` | Вложения Сообщений | keep | P1 |
| `path.mail-downloads` | Вложения Почты | caution | P2 |
| `path.docker-raw` | Docker.raw: диск виртуальной машины Docker | caution | P1 |
| `path.package-caches` | Кэши пакетных менеджеров (Homebrew, npm, pnpm, yarn, pip, uv) | safe | P1 |
| `path.jvm-caches` | Gradle и Maven | safe | P2 |
| `path.cocoapods` | CocoaPods и Carthage | safe | P2 |
| `path.ml-models` | Модели ИИ (Hugging Face, Ollama, LM Studio) | caution | P1 |
| `path.project-artifacts` | node_modules, target, build в проектах | caution | P1 |
| `path.old-installers` | Установщики .dmg и .pkg в Загрузках | safe | P1 |
| `path.trash` | Корзина | caution | P1 |
| `path.app-electron-caches` | Кэши Slack, Discord, Teams (Cache, Code Cache, Service Worker) | safe | P2 |
| `path.browser-caches` | Кэши браузеров | safe | P2 |
| `path.audio-libraries` | Библиотеки звуков GarageBand и Logic | caution | P2 |
| `path.containers` | ~/Library/Containers и Group Containers | caution | P2 |
| `path.var-folders` | /private/var/folders: временные файлы системы | keep | P2 |
| `path.swap` | Файл подкачки /private/var/vm | keep | P1 |

### Guides

| id | Title | Wave |
|---|---|---|
| `guide.system-data` | Почему «Системные данные» занимают так много | P1 |
| `guide.space-not-freed` | Удалил, а места не прибавилось: Корзина, очищаемое место, локальные снимки | P1 |
| `guide.memory-pressure` | Как читать давление памяти, сжатие и своп | P1 |
| `guide.high-swap` | Своп растёт: что закрыть и когда перезагрузиться | P1 |
| `guide.no-ram-cleaners` | Почему «очистка оперативки» не помогает | P1 |
| `guide.slow-after-update` | Mac тормозит после обновления macOS | P1 |
| `guide.browser-memory` | Браузер ест память: вкладки, расширения, режимы экономии | P1 |
| `guide.login-items` | Объекты входа и фоновые объекты | P1 |
| `guide.downloads-cleanup` | Как разобрать «Загрузки» | P1 |
| `guide.desktop-organization` | Порядок на Рабочем столе: стопки и папки | P1 |
| `guide.file-organization` | Как организовать файлы: структура папок, теги, смарт-папки | P1 |
| `guide.optimize-storage` | Оптимизация хранилища: iCloud Drive, Фото, Музыка | P1 |
| `guide.free-space-target` | Сколько свободного места держать и зачем | P1 |
| `guide.caches-explained` | Что такое кэш и почему его можно удалить | P1 |
| `guide.uninstall-apps` | Как правильно удалять программы и их остатки | P1 |
| `guide.fda` | Зачем SpotlessMac нужен полный доступ к диску | P1 |
| `guide.spotlight-exclude` | Как исключить папки из индексации Spotlight | P1 |
| `guide.time-machine` | Time Machine: локальные снимки и копии на диске | P2 |
| `guide.restart-when` | Когда перезагрузка действительно помогает | P2 |
| `guide.heat-fans` | Mac греется и шумит: что проверить | P2 |
| `guide.large-media` | Крупные видео и архивы: где искать и как хранить | P1 |
| `guide.mail-messages-storage` | Почта и Сообщения занимают место | P2 |
| `guide.macos-update-space` | Сколько места нужно для обновления macOS | P2 |
| `guide.developer-disk` | Диск разработчика: что съедает место | P2 |

Totals: P1 = 49 (15 processes/apps, 16 paths, 18 guides), P2 = 25. Coverage check: every `ScanCategory` has a fallback
(`user_caches`→`path.user-caches`, `developer_caches`→`path.package-caches`, `logs`→`path.logs`,
`trash`→`path.trash`, `large_files`→`guide.large-media`,
`old_installers`→`path.old-installers`, `model_caches`→`path.ml-models`,
`known_app_caches`→`path.user-caches`, `project_artifacts`→`path.project-artifacts`,
`recordings`→`guide.file-organization`).

### Authoring process

1. Draft from Apple Support / Apple Developer docs / man pages / vendor docs, in our own words
   (no copied text from third-party sites; links in `sources` are fine).
2. Every Settings path and menu name is checked on a real Mac for each version in `macOS`; no terminal commands.
3. Human review sets `reviewed`; corpus test and eval set must pass.
4. Each new article adds 1–2 eval queries.

## 10. Error handling

- Missing or empty `Knowledge` folder in the bundle → empty base, `Logger` error, assistant
  works as before; the corpus test prevents shipping that state.
- One malformed article → skipped and logged; others load (Debug builds additionally
  `assertionFailure` so it is noticed during development).
- Tool errors follow the existing pattern: text returned to the model, never thrown.

## 11. Out of scope / later

- **Remote updates**: signed JSON bundle on static hosting, verified like the license, cached in
  Application Support; bundled copy as the fallback.
- **Sources in the chat UI**: chips under an answer naming the articles used, with a viewer.
- **Reuse outside chat**: «Что это?» popovers in «Память» and «Освободить место» from the same articles.
- **`ImprovementAdvisor` hints** driven by article matches.
- **Web search** (Ollama `web_search` with the user's key), opt-in and labelled as unverified.
- **Server-side base**: only if the app starts offering a built-in AI subscription.
- English localization.
