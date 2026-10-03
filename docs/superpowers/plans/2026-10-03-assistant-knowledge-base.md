# Assistant Knowledge Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a bundled, reviewed knowledge base about macOS that the cleanup assistant sees automatically (articles bound to scanned folders, memory apps and processes) and can search with a new `lookup_knowledge` tool.

**Architecture:** Articles are Markdown files with a flat front matter in a blue folder reference `SpotlessMac/Resources/Knowledge/`. Parsing, BM25 search, snapshot matching and rendering are pure-Swift value types under `SpotlessMac/Assistant/` (so the isolation guard covers them). `AssistantViewModel` receives an immutable `KnowledgeBase` through its dependencies; the renderer adds a «справка» column and a «Справка по найденному» section; the toolbox gains a read-only `lookup_knowledge` tool; without tool support the top hits are injected as a system message.

**Tech Stack:** Swift 6, Foundation + os only inside `Assistant/`, XCTest, Xcode 16.2 project (non-synchronized groups; new files registered with `scripts/xcodeproj-add.py`).

**Spec:** `docs/superpowers/specs/2026-10-03-assistant-knowledge-base-design.md`

## Prerequisite

The prompt-injection guard (`SpotlessMac/Assistant/AssistantGuard.swift`, uncommitted on `main` when this plan was written, together with edits to `AssistantPrompt.swift`, `AssistantViewModel.swift`, `AssistantViewModelTests.swift`, `CLAUDE.md`) must be committed before Task 1 starts. Then create the working branch from that commit. This plan's code is written against the guard's signatures: `AssistantPrompt.system(toolsEnabled:tokens:)`, `AssistantPrompt.guardrails(tokens:)`, `systemMessages(toolsEnabled:context:tokens:)`, `AssistantGuard.fence(_:tokens:)`, `AssistantGuard.looksLikeCommand(_:)`. If any of them changed by then, adapt the Task 9 steps to the committed version, keeping their intent.

## Global Constraints

- CLAUDE.md rule 6: `SpotlessMac/Assistant/` gets no deletion, process-quit, process-spawn, Docker or uninstall API. Never weaken `AssistantIsolationTests` token lists; only extend expected names/labels where this plan says so.
- Files under `SpotlessMac/Assistant/` import only `Foundation`, `Observation`, `os`.
- CLAUDE.md `AssistantGuard` rule: keep all four guard layers (input refusal, fencing of snapshot/tool output, prompt-leak canary, hiding code and terminal commands). The assistant never suggests terminal commands, so **articles contain no shell commands and no code fences at all** — the lint uses `AssistantGuard.looksLikeCommand`.
- Bundled article text is trusted: the tools-off reference goes out as its own system message, unfenced. Tool results (including `lookup_knowledge`) keep going through `AssistantGuard.fence`, as all tool output does.
- No `FileManager` and no `URL(fileURLWithPath` in `Assistant/` (bundle loading uses `Bundle.urls(forResourcesWithExtension:subdirectory:)` and `String(contentsOf:encoding:)`).
- Articles: Russian; front matter strict subset (one `key: value` per line, lists only inline `[a, b]`, items cannot contain commas, optional double quotes, no nesting); `summary` ≤ 160 characters; body 400–2,500 characters; sections in order `## Что это`, `## Норма`, `## Почему растёт`, `## Что делать`, `## Чего не делать` (first and fourth required).
- Verdict labels: `safe` «безопасно», `caution` «осторожно», `keep` «не трогать», `info` «справка».
- Limits: single article in a tool result ≤ 3,000 chars; `lookup_knowledge` query result ≤ 6,000; «Справка по найденному» ≤ 12 entries and ≤ 2,500 chars; tools-off injection: top 2 hits, ≤ 4,000 chars.
- Snapshot item column order becomes `ID | путь | размер | категория | политика | изменён | владелец | справка`.
- SpotlessMac UI names used in articles and prompt: tabs «Уход», «Чистка», «Программы», «Диск», «Память», «Docker», «Ассистент», «Настройки»; the cleanup review screen is «Освободить место» (tab «Диск»).
- Retrieval eval: ≥ 90% of eval queries return the expected article in the top 3.
- Build: `xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO`. Tests: `scripts/test.sh [TestClass ...]`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A broken article in a release build** — the app must still start and the assistant must still answer (article skipped, logged); covered by `KnowledgeBaseTests.testBuildSkipsBrokenFilesAndKeepsTheRest` (Task 3).
2. **Cloud redaction** — knowledge annotation must not leak real paths or project names to cloud providers; the section shows only article ids/summaries, and `.other` process names go through `formatPath`; covered by `SnapshotRendererTests.testTopProcessNamesAreFormatted` and `AssistantViewModelTests.testCloudRequestWithKnowledgeStaysRedacted` (Tasks 7, 9).
3. **Model-supplied junk arguments** to `lookup_knowledge` (numbers, booleans, empty strings, both fields missing) must produce an error text, never a crash or an empty success; covered in `AssistantToolboxTests` (Task 8).
4. **Protected folders called safe** — an article pattern broad enough to cover the Photos library, iCloud Drive, Messages, iPhone backups, `/System` or swap with `verdict: safe`; covered by `KnowledgeCorpusTests.testSafeArticlesNeverCoverProtectedRoots` (Task 6).
5. **Tools switched off mid-answer** (`toolsUnsupported` fallback on round 0) — the retried request must carry the injected reference; covered by `AssistantViewModelTests.testFallbackRequestInjectsReferenceAfterToolsUnsupported` (Task 9).

## Execution order and parallelism

```
Task 1 → Task 2 → Task 3 → Task 4 ──┬──▶ Tasks 10, 11, 12 (content, parallel) ──┐
Task 5 (independent) ───────────────┴──▶ Task 6 → Task 7 → Task 8 → Task 9 ────┴──▶ Task 13
```

Content tasks touch only `SpotlessMac/Resources/Knowledge/*.md` and their own `SpotlessMacTests/Fixtures/knowledge-eval-*.json`, so they run in parallel with each other and with Tasks 6–9 without merge conflicts. Code tasks 1–9 all edit `project.pbxproj` or shared Swift files; run them sequentially.

## File map

| File | Task | Responsibility |
|---|---|---|
| `SpotlessMac/Assistant/KnowledgeArticle.swift` | 1 | `KnowledgeKind`, `KnowledgeVerdict`, `KnowledgeArticle` |
| `SpotlessMac/Assistant/KnowledgeParser.swift` | 1 | Front matter + section parser, `KnowledgeParseError` |
| `SpotlessMac/Assistant/KnowledgeSearch.swift` | 2 | Tokenizer, stemming, BM25, `KnowledgeHit` |
| `SpotlessMac/Assistant/KnowledgeBase.swift` | 3 | Article set, lookup, `build(files:)`, `loadBundled(from:)` |
| `SpotlessMac/Resources/Knowledge/*.md` | 3, 10–12 | Articles |
| `scripts/xcodeproj-add.py` | 3 | New `resource-folder` mode |
| `SpotlessMac/Assistant/SystemSnapshot.swift` | 5 | `MemoryAppInfo.bundleID`, `MemoryProcessInfo`, `MemoryInfo.topProcesses` |
| `SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift` | 5 | Fills the new memory fields |
| `SpotlessMac/Assistant/KnowledgeMatcher.swift` | 6 | `KnowledgeAnnotations`, `KnowledgeContext`, matching rules |
| `SpotlessMac/Assistant/KnowledgeRenderer.swift` | 7 | Article text, lookup result, section, tools-off injection |
| `SpotlessMac/Assistant/SnapshotRenderer.swift` | 7 | «справка» column, memory annotations, top processes, section |
| `SpotlessMac/Assistant/AssistantTool.swift`, `AssistantToolbox.swift` | 8 | `lookup_knowledge` |
| `SpotlessMac/Assistant/AssistantViewModel.swift`, `AssistantPrompt.swift`, `App/ContentView.swift` | 9 | Wiring, prompt, injection |
| `SpotlessMacTests/KnowledgeFixtures.swift` | 1 | Shared test articles |
| `SpotlessMacTests/Knowledge*Tests.swift` | 1–4, 6, 13 | Tests |
| `SpotlessMacTests/Fixtures/knowledge-eval-*.json` | 4, 10–12 | Retrieval eval queries (read via `#filePath`, not part of any target) |

---

### Task 1: Article model and parser

**Files:**
- Create: `SpotlessMac/Assistant/KnowledgeArticle.swift`
- Create: `SpotlessMac/Assistant/KnowledgeParser.swift`
- Create: `SpotlessMacTests/KnowledgeFixtures.swift`
- Create: `SpotlessMacTests/KnowledgeParserTests.swift`
- Modify: `SpotlessMac.xcodeproj/project.pbxproj` (via script)

**Interfaces:**
- Consumes: `ScanCategory` (`SpotlessMac/Models/ScanCategory.swift`, `String` raw values such as `user_caches`).
- Produces:
  - `enum KnowledgeKind: String { case process, app, path, guide; var idPrefix: String }`
  - `enum KnowledgeVerdict: String { case safe, caution, keep, info; var label: String }`
  - `struct KnowledgeArticle: Equatable, Sendable, Identifiable` with memberwise init `(id:kind:title:summary:verdict:aliases:keywords:processes:bundles:paths:categories:related:macOS:reviewed:sources:body:)`
  - `enum KnowledgeParser { static let maxSummaryLength = 160; static let sectionOrder: [String]; static let requiredSections: [String]; static func parse(_ text: String, fileName: String) throws(KnowledgeParseError) -> KnowledgeArticle }`
  - `enum KnowledgeParseError: Error, Equatable, CustomStringConvertible`
  - Test helper `KnowledgeFixtures.body`, `KnowledgeFixtures.article(...)`, `KnowledgeFixtures.base(...)` (the last one added in Task 3).

- [ ] **Step 1: Write the test fixtures and failing parser tests**

`SpotlessMacTests/KnowledgeFixtures.swift`:

```swift
import Foundation
@testable import SpotlessMac

enum KnowledgeFixtures {
    static let body = """
    ## Что это
    Образец статьи для тестов.

    ## Что делать
    Ничего не делать.
    """

    static func article(
        _ id: String, kind: KnowledgeKind = .guide, title: String? = nil, summary: String = "Кратко.",
        verdict: KnowledgeVerdict = .info, aliases: [String] = [], keywords: [String] = [],
        processes: [String] = [], bundles: [String] = [], paths: [String] = [],
        categories: [ScanCategory] = [], related: [String] = [], body: String = body
    ) -> KnowledgeArticle {
        KnowledgeArticle(
            id: id, kind: kind, title: title ?? id, summary: summary, verdict: verdict,
            aliases: aliases, keywords: keywords, processes: processes, bundles: bundles, paths: paths,
            categories: categories, related: related, macOS: nil, reviewed: "2026-10-03", sources: [], body: body
        )
    }
}
```

`SpotlessMacTests/KnowledgeParserTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class KnowledgeParserTests: XCTestCase {
    private let front = """
    id: proc.sample
    kind: process
    title: "Sample: процесс"
    summary: Короткое описание.
    verdict: keep
    aliases: [образец, "sample one"]
    processes: [sampled, sample_helper]
    categories: [user_caches]
    macOS: 14-26
    reviewed: 2026-10-03
    sources: [https://support.apple.com/example, man:sampled]
    """

    private func file(_ front: String, body: String = KnowledgeFixtures.body) -> String {
        "---\n\(front)\n---\n\(body)"
    }

    private func assertError(_ text: String, fileName: String = "proc.sample.md", _ expected: KnowledgeParseError,
                             line: UInt = #line) {
        XCTAssertThrowsError(try KnowledgeParser.parse(text, fileName: fileName), line: line) { error in
            XCTAssertEqual(error as? KnowledgeParseError, expected, line: line)
        }
    }

    func testParsesValidArticle() throws {
        let article = try KnowledgeParser.parse(file(front), fileName: "proc.sample.md")
        XCTAssertEqual(article.id, "proc.sample")
        XCTAssertEqual(article.kind, .process)
        XCTAssertEqual(article.title, "Sample: процесс")
        XCTAssertEqual(article.summary, "Короткое описание.")
        XCTAssertEqual(article.verdict, .keep)
        XCTAssertEqual(article.aliases, ["образец", "sample one"])
        XCTAssertEqual(article.processes, ["sampled", "sample_helper"])
        XCTAssertEqual(article.categories, [.userCaches])
        XCTAssertEqual(article.macOS, "14-26")
        XCTAssertEqual(article.reviewed, "2026-10-03")
        XCTAssertEqual(article.sources, ["https://support.apple.com/example", "man:sampled"])
        XCTAssertEqual(article.keywords, [])
        XCTAssertTrue(article.body.hasPrefix("## Что это"))
    }

    func testWindowsLineEndingsAreAccepted() throws {
        let text = file(front).replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try KnowledgeParser.parse(text, fileName: "proc.sample.md").id, "proc.sample")
    }

    func testEmptyListIsAllowed() throws {
        let article = try KnowledgeParser.parse(file(front + "\nkeywords: []"), fileName: "proc.sample.md")
        XCTAssertEqual(article.keywords, [])
    }

    func testMissingFrontMatter() {
        assertError("## Что это\nтекст", .missingFrontMatter)
        assertError("---\nid: proc.sample\n## Что это", .missingFrontMatter)
    }

    func testMalformedLine() {
        assertError(file(front + "\nне ключ"), .malformedLine("не ключ"))
    }

    func testMissingRequiredField() {
        let noSummary = front.components(separatedBy: "\n").filter { !$0.hasPrefix("summary:") }.joined(separator: "\n")
        assertError(file(noSummary), .missingField("summary"))
    }

    func testUnknownKey() {
        assertError(file(front + "\ntags: [a]"), .unknownKey("tags"))
    }

    func testDuplicateKey() {
        assertError(file(front + "\nverdict: safe"), .duplicateKey("verdict"))
    }

    func testListMustUseBrackets() {
        assertError(file(front + "\nkeywords: a, b"), .invalidValue(field: "keywords", value: "a, b"))
    }

    func testUnknownEnumValues() {
        assertError(file(front.replacingOccurrences(of: "verdict: keep", with: "verdict: maybe")),
                    .invalidValue(field: "verdict", value: "maybe"))
        assertError(file(front.replacingOccurrences(of: "kind: process", with: "kind: daemon")),
                    .invalidValue(field: "kind", value: "daemon"))
        assertError(file(front.replacingOccurrences(of: "[user_caches]", with: "[caches]")),
                    .invalidValue(field: "categories", value: "caches"))
    }

    func testReviewedMustBeADate() {
        assertError(file(front.replacingOccurrences(of: "2026-10-03", with: "вчера")),
                    .invalidValue(field: "reviewed", value: "вчера"))
    }

    func testIdMustMatchFileName() {
        assertError(file(front), fileName: "proc.other.md", .idMismatch(id: "proc.sample", fileName: "proc.other.md"))
    }

    func testIdPrefixMustMatchKind() {
        let text = file(front.replacingOccurrences(of: "id: proc.sample", with: "id: app.sample"))
        assertError(text, fileName: "app.sample.md", .invalidValue(field: "id", value: "app.sample"))
    }

    func testSummaryLengthIsCapped() {
        let long = String(repeating: "а", count: 161)
        assertError(file(front.replacingOccurrences(of: "Короткое описание.", with: long)), .summaryTooLong(161))
    }

    func testRequiredSections() {
        assertError(file(front, body: "## Что это\nтекст"), .missingSection("Что делать"))
    }

    func testUnknownSection() {
        assertError(file(front, body: "## Что это\nа\n## Советы\nб\n## Что делать\nв"), .unknownSection("Советы"))
    }

    func testSectionsOutOfOrder() {
        assertError(file(front, body: "## Что делать\nа\n## Что это\nб"), .sectionsOutOfOrder)
    }
}
```

- [ ] **Step 2: Register the test files and run them to see them fail**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeFixtures.swift SpotlessMacTests/KnowledgeParserTests.swift
scripts/test.sh KnowledgeParserTests
```

Expected: `BUILD FAILED` / `error: cannot find 'KnowledgeParser' in scope`.

- [ ] **Step 3: Implement the model**

`SpotlessMac/Assistant/KnowledgeArticle.swift`:

```swift
import Foundation

enum KnowledgeKind: String, Sendable, CaseIterable {
    case process, app, path, guide

    var idPrefix: String {
        switch self {
        case .process: "proc."
        case .app: "app."
        case .path: "path."
        case .guide: "guide."
        }
    }
}

enum KnowledgeVerdict: String, Sendable, CaseIterable {
    case safe, caution, keep, info

    var label: String {
        switch self {
        case .safe: "безопасно"
        case .caution: "осторожно"
        case .keep: "не трогать"
        case .info: "справка"
        }
    }
}

// One reviewed article of the bundled knowledge base. Read-only data: it only ever becomes prompt text.
struct KnowledgeArticle: Equatable, Sendable, Identifiable {
    let id: String
    let kind: KnowledgeKind
    let title: String
    let summary: String
    let verdict: KnowledgeVerdict
    var aliases: [String] = []
    var keywords: [String] = []
    var processes: [String] = []
    var bundles: [String] = []
    var paths: [String] = []
    var categories: [ScanCategory] = []
    var related: [String] = []
    var macOS: String?
    var reviewed: String = ""
    var sources: [String] = []
    var body: String = ""
}
```

- [ ] **Step 4: Implement the parser**

`SpotlessMac/Assistant/KnowledgeParser.swift`:

```swift
import Foundation

enum KnowledgeParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontMatter
    case malformedLine(String)
    case unknownKey(String)
    case duplicateKey(String)
    case missingField(String)
    case invalidValue(field: String, value: String)
    case idMismatch(id: String, fileName: String)
    case summaryTooLong(Int)
    case unknownSection(String)
    case missingSection(String)
    case sectionsOutOfOrder

    var description: String {
        switch self {
        case .missingFrontMatter: "no front matter between --- lines"
        case .malformedLine(let line): "malformed front matter line: \(line)"
        case .unknownKey(let key): "unknown key: \(key)"
        case .duplicateKey(let key): "duplicate key: \(key)"
        case .missingField(let key): "missing required field: \(key)"
        case .invalidValue(let field, let value): "invalid \(field): \(value)"
        case .idMismatch(let id, let fileName): "id \(id) does not match file \(fileName)"
        case .summaryTooLong(let count): "summary is \(count) characters, max \(KnowledgeParser.maxSummaryLength)"
        case .unknownSection(let title): "unknown section: \(title)"
        case .missingSection(let title): "missing section: \(title)"
        case .sectionsOutOfOrder: "sections out of order"
        }
    }
}

// Parses one article file: a flat front matter between `---` lines, then the Markdown body.
// Front matter is a strict YAML subset: `key: value` per line, lists only as inline `[a, b]`
// (items cannot contain commas), optional double quotes, no nesting. Unknown keys are errors.
enum KnowledgeParser {
    static let maxSummaryLength = 160
    static let sectionOrder = ["Что это", "Норма", "Почему растёт", "Что делать", "Чего не делать"]
    static let requiredSections = ["Что это", "Что делать"]
    private static let scalarKeys: Set<String> = ["id", "kind", "title", "summary", "verdict", "macOS", "reviewed"]
    private static let listKeys: Set<String> = [
        "aliases", "keywords", "processes", "bundles", "paths", "categories", "related", "sources",
    ]

    static func parse(_ text: String, fileName: String) throws(KnowledgeParseError) -> KnowledgeArticle {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw .missingFrontMatter }

        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for line in lines[1..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformedLine(line) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard scalars[key] == nil, lists[key] == nil else { throw .duplicateKey(key) }
            if scalarKeys.contains(key) {
                scalars[key] = unquoted(value)
            } else if listKeys.contains(key) {
                guard value.hasPrefix("["), value.hasSuffix("]") else { throw .invalidValue(field: key, value: value) }
                let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                lists[key] = inner.isEmpty ? [] : inner.split(separator: ",").map {
                    unquoted($0.trimmingCharacters(in: .whitespaces))
                }
            } else {
                throw .unknownKey(key)
            }
        }

        func required(_ key: String) throws(KnowledgeParseError) -> String {
            guard let value = scalars[key], !value.isEmpty else { throw .missingField(key) }
            return value
        }
        let id = try required("id")
        let kindValue = try required("kind")
        guard let kind = KnowledgeKind(rawValue: kindValue) else { throw .invalidValue(field: "kind", value: kindValue) }
        let idCharacters = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        guard id.hasPrefix(kind.idPrefix), idCharacters else { throw .invalidValue(field: "id", value: id) }
        let baseName = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        guard baseName == id else { throw .idMismatch(id: id, fileName: fileName) }
        let title = try required("title")
        let summary = try required("summary")
        guard summary.count <= maxSummaryLength else { throw .summaryTooLong(summary.count) }
        let verdictValue = try required("verdict")
        guard let verdict = KnowledgeVerdict(rawValue: verdictValue) else {
            throw .invalidValue(field: "verdict", value: verdictValue)
        }
        let reviewed = try required("reviewed")
        guard reviewed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw .invalidValue(field: "reviewed", value: reviewed)
        }
        var categories: [ScanCategory] = []
        for value in lists["categories"] ?? [] {
            guard let category = ScanCategory(rawValue: value) else { throw .invalidValue(field: "categories", value: value) }
            categories.append(category)
        }

        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        try checkSections(body)

        return KnowledgeArticle(
            id: id, kind: kind, title: title, summary: summary, verdict: verdict,
            aliases: lists["aliases"] ?? [], keywords: lists["keywords"] ?? [],
            processes: lists["processes"] ?? [], bundles: lists["bundles"] ?? [], paths: lists["paths"] ?? [],
            categories: categories, related: lists["related"] ?? [], macOS: scalars["macOS"],
            reviewed: reviewed, sources: lists["sources"] ?? [], body: body
        )
    }

    private static func checkSections(_ body: String) throws(KnowledgeParseError) {
        let titles = body.components(separatedBy: "\n")
            .filter { $0.hasPrefix("## ") }
            .map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        var last = -1
        for title in titles {
            guard let index = sectionOrder.firstIndex(of: title) else { throw .unknownSection(title) }
            guard index > last else { throw .sectionsOutOfOrder }
            last = index
        }
        for title in requiredSections where !titles.contains(title) { throw .missingSection(title) }
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
```

- [ ] **Step 5: Register the sources and run the tests**

```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/KnowledgeArticle.swift SpotlessMac/Assistant/KnowledgeParser.swift
scripts/test.sh KnowledgeParserTests AssistantIsolationTests
```

Expected: all `KnowledgeParserTests` and `AssistantIsolationTests` cases pass, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/Assistant/KnowledgeArticle.swift SpotlessMac/Assistant/KnowledgeParser.swift \
  SpotlessMacTests/KnowledgeFixtures.swift SpotlessMacTests/KnowledgeParserTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(knowledge): article model and front matter parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Search (tokenizer, stemming, BM25)

**Files:**
- Create: `SpotlessMac/Assistant/KnowledgeSearch.swift`
- Create: `SpotlessMacTests/KnowledgeSearchTests.swift`

**Interfaces:**
- Consumes: `KnowledgeArticle`, `KnowledgeFixtures.article(...)` (Task 1).
- Produces:
  - `struct KnowledgeHit: Equatable, Sendable { let article: KnowledgeArticle; let score: Double }`
  - `struct KnowledgeSearch: Sendable { init(articles: [KnowledgeArticle]); func search(_ query: String, limit: Int) -> [KnowledgeHit]; static func tokens(_ text: String) -> [String]; static func stem(_ word: String) -> String }`

- [ ] **Step 1: Write the failing tests**

`SpotlessMacTests/KnowledgeSearchTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class KnowledgeSearchTests: XCTestCase {
    func testTokensSplitIdentifiersButKeepThemWhole() {
        XCTAssertEqual(KnowledgeSearch.tokens("mds_stores"), ["mds_stores", "mds", "stores"])
        let bundle = KnowledgeSearch.tokens("com.google.Chrome")
        XCTAssertEqual(bundle.first, "com.google.chrome")
        XCTAssertTrue(bundle.contains("google"))
        XCTAssertTrue(bundle.contains("chrome"))
    }

    func testStopWordsAreDroppedAndYoIsNormalized() {
        XCTAssertEqual(KnowledgeSearch.tokens("Что это за кэш?"), ["кэш"])
        XCTAssertEqual(KnowledgeSearch.tokens("растёт"), KnowledgeSearch.tokens("растет"))
    }

    func testStemmingMergesRussianWordForms() {
        let pairs = [("кэши", "кэш"), ("памяти", "память"), ("индексация", "индексирует"), ("данных", "данные"),
                     ("обновления", "обновлений"), ("загрузки", "загрузок"), ("файлов", "файлы")]
        for (left, right) in pairs {
            XCTAssertEqual(KnowledgeSearch.stem(left), KnowledgeSearch.stem(right), "\(left) / \(right)")
        }
        XCTAssertEqual(KnowledgeSearch.stem("chrome"), "chrome")
    }

    func testExactProcessNameRanksFirst() {
        let noisy = KnowledgeFixtures.article("guide.noise", title: "Шум", body: String(repeating: "mds stores ", count: 40))
        let target = KnowledgeFixtures.article("proc.spotlight", kind: .process, title: "Spotlight", processes: ["mds_stores"])
        let search = KnowledgeSearch(articles: [noisy, target])
        XCTAssertEqual(search.search("что за mds_stores?", limit: 3).first?.article.id, "proc.spotlight")
    }

    func testTitleOutweighsBody() {
        let titled = KnowledgeFixtures.article("guide.swap", title: "Своп и подкачка")
        let mentioned = KnowledgeFixtures.article("guide.other", title: "Другое", body: "Тут однажды упомянут своп.")
        let hits = KnowledgeSearch(articles: [mentioned, titled]).search("своп", limit: 3)
        XCTAssertEqual(hits.map(\.article.id), ["guide.swap", "guide.other"])
    }

    func testAliasesAndStemmedFormsMatch() {
        let article = KnowledgeFixtures.article("guide.ram", title: "Давление памяти", aliases: ["оперативка"])
        let search = KnowledgeSearch(articles: [article, KnowledgeFixtures.article("guide.x", title: "Диск")])
        XCTAssertEqual(search.search("оперативка занята", limit: 1).first?.article.id, "guide.ram")
        XCTAssertEqual(search.search("не хватает памяти", limit: 1).first?.article.id, "guide.ram")
    }

    func testNoMatchEmptyQueryAndLimit() {
        let articles = (1...5).map { KnowledgeFixtures.article("guide.a\($0)", title: "Кэш номер \($0)") }
        let search = KnowledgeSearch(articles: articles)
        XCTAssertEqual(search.search("zzzz", limit: 3), [])
        XCTAssertEqual(search.search("   ", limit: 3), [])
        XCTAssertEqual(search.search("кэш", limit: 0), [])
        XCTAssertEqual(search.search("кэш", limit: 2).count, 2)
    }

    func testEmptyIndexReturnsNothing() {
        XCTAssertEqual(KnowledgeSearch(articles: []).search("кэш", limit: 3), [])
    }
}
```

- [ ] **Step 2: Register and run to see them fail**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeSearchTests.swift
scripts/test.sh KnowledgeSearchTests
```

Expected: build error `cannot find 'KnowledgeSearch' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/KnowledgeSearch.swift`:

```swift
import Foundation

struct KnowledgeHit: Equatable, Sendable {
    let article: KnowledgeArticle
    let score: Double
}

// BM25 over the bundled articles, in memory. A few hundred short articles need no database:
// the index is built once and each query scores every document.
struct KnowledgeSearch: Sendable {
    static let k1 = 1.2
    static let b = 0.75
    // Added when a query word equals one of the article's process names or bundle IDs.
    static let exactMatchBoost = 5.0
    static let stopWords: Set<String> = [
        "и", "в", "во", "на", "с", "со", "за", "по", "к", "ко", "о", "об", "а", "но", "не", "ни", "что", "это",
        "как", "ли", "же", "у", "из", "от", "до", "для", "мой", "моя", "мне", "меня", "я", "ты", "он", "она",
        "оно", "они", "мы", "вы", "так", "там", "тут", "есть", "или", "можно", "ли",
        "the", "a", "an", "of", "to", "is", "what", "and", "or",
    ]
    // Two-letter adjective/plural endings stripped before the vowel pass (only if ≥ 4 letters remain).
    private static let pairEndings = ["ых", "их", "ой", "ей", "ий", "ый", "ая", "яя", "ое", "ее", "ые", "ие", "ую", "юю", "ах", "ях", "ов", "ев"]
    private static let vowelEndings = Set("аеиоуыэюяьй")
    private static let stemLength = 5

    private struct Document: Sendable {
        let article: KnowledgeArticle
        let frequencies: [String: Double]
        let length: Double
        let exactNames: Set<String>
    }

    private let documents: [Document]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    init(articles: [KnowledgeArticle]) {
        documents = articles.map(Self.document)
        var frequency: [String: Int] = [:]
        for document in documents {
            for term in document.frequencies.keys { frequency[term, default: 0] += 1 }
        }
        documentFrequency = frequency
        let total = documents.reduce(0) { $0 + $1.length }
        averageLength = documents.isEmpty ? 1 : max(total / Double(documents.count), 1)
    }

    func search(_ query: String, limit: Int) -> [KnowledgeHit] {
        guard limit > 0, !documents.isEmpty else { return [] }
        let terms = Set(Self.tokens(query))
        let words = Set(query.lowercased()
            .split { $0.isWhitespace || "?!,;:«»\"()".contains($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let count = Double(documents.count)
        var hits: [KnowledgeHit] = []
        for document in documents {
            var score = 0.0
            for term in terms {
                guard let tf = document.frequencies[term], let df = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(df) + 0.5) / (Double(df) + 0.5))
                let norm = tf + Self.k1 * (1 - Self.b + Self.b * document.length / averageLength)
                score += idf * tf * (Self.k1 + 1) / norm
            }
            if !document.exactNames.isDisjoint(with: words) { score += Self.exactMatchBoost }
            if score > 0 { hits.append(KnowledgeHit(article: document.article, score: score)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.article.id < $1.article.id }
        return Array(hits.prefix(limit))
    }

    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        var result: [String] = []
        for raw in lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
            guard !word.isEmpty else { continue }
            let parts = word.split(whereSeparator: { $0 == "_" || $0 == "." }).map(String.init)
            if parts.count > 1 { result.append(word) }
            for part in parts where !stopWords.contains(part) { result.append(stem(part)) }
        }
        return result
    }

    // Light Russian stemming: drop one two-letter ending, then trailing vowels, then cut to five letters.
    // Latin words are left whole. Tuned against the eval set (KnowledgeEvalTests), not linguistically exact.
    static func stem(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else { return word }
        var characters = Array(word)
        if characters.count >= 6, pairEndings.contains(String(characters.suffix(2))) { characters.removeLast(2) }
        while characters.count > 3, let last = characters.last, vowelEndings.contains(last) { characters.removeLast() }
        return String(characters.prefix(stemLength))
    }

    private static func document(_ article: KnowledgeArticle) -> Document {
        var frequencies: [String: Double] = [:]
        var length = 0.0
        func add(_ text: String, weight: Double) {
            for token in tokens(text) {
                frequencies[token, default: 0] += weight
                length += weight
            }
        }
        add(article.title, weight: 3)
        for value in article.aliases + article.keywords + article.processes + article.bundles { add(value, weight: 2) }
        add(article.summary, weight: 1.5)
        add(article.body, weight: 1)
        let names = Set((article.processes + article.bundles).map { $0.lowercased() })
        return Document(article: article, frequencies: frequencies, length: length, exactNames: names)
    }
}
```

- [ ] **Step 4: Register and run**

```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/KnowledgeSearch.swift
scripts/test.sh KnowledgeSearchTests AssistantIsolationTests
```

Expected: PASS. If a stemming pair fails, adjust `pairEndings`/`vowelEndings` (not the test pairs) until all pairs match; keep `stem("chrome") == "chrome"`.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/KnowledgeSearch.swift SpotlessMacTests/KnowledgeSearchTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(knowledge): BM25 search with light Russian stemming

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Knowledge base, bundled resource folder, seed articles, corpus lint

**Files:**
- Create: `SpotlessMac/Assistant/KnowledgeBase.swift`
- Create: `SpotlessMac/Resources/Knowledge/proc.spotlight-indexing.md`
- Create: `SpotlessMac/Resources/Knowledge/path.xcode-deriveddata.md`
- Create: `SpotlessMac/Resources/Knowledge/guide.memory-pressure.md`
- Modify: `scripts/xcodeproj-add.py` (new `resource-folder` mode)
- Modify: `SpotlessMacTests/KnowledgeFixtures.swift` (add `base(_:)`)
- Create: `SpotlessMacTests/KnowledgeBaseTests.swift`
- Create: `SpotlessMacTests/KnowledgeCorpusTests.swift`

**Interfaces:**
- Consumes: `KnowledgeParser.parse`, `KnowledgeSearch` (Tasks 1–2).
- Produces:
  - `struct KnowledgeBase: Sendable { static let empty; static let resourceFolder = "Knowledge"; let articles: [KnowledgeArticle] /* sorted by id */; var isEmpty: Bool; func article(id: String) -> KnowledgeArticle?; func search(_ query: String, limit: Int) -> [KnowledgeHit]; static func build(files: [(name: String, text: String)]) -> (base: KnowledgeBase, failures: [String]); static func loadBundled(from bundle: Bundle) -> KnowledgeBase }`
  - `KnowledgeCorpusTests.sourceFiles` (static, throwing) and `KnowledgeCorpusTests.wave1` (`Set<String>` of the 49 wave-1 ids), reused by Tasks 4, 6, 13.
  - `KnowledgeFixtures.base(_ articles: [KnowledgeArticle]) -> KnowledgeBase`.

- [ ] **Step 1: Extend the project script with a resource-folder mode**

In `scripts/xcodeproj-add.py`, update the usage docstring with
`scripts/xcodeproj-add.py resource-folder Resources SpotlessMac/Resources/Knowledge`, add after `APP_ROOT_GROUP`:

```python
RESOURCES_PHASE = "BB000004000000000000BB00"


def add_resource_folder(text: str, group_id: str, folder: str) -> str:
    """Adds a blue folder reference copied as-is into Contents/Resources."""
    name = Path(folder).name
    ref_id, build_id = make_id("ref", folder), make_id("build", folder)
    if ref_id in text:
        return text
    text = insert_after(text, "/* Begin PBXFileReference section */",
                        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder; "
                        f"path = {name}; sourceTree = \"<group>\"; }};")
    text = insert_after(text, "/* Begin PBXBuildFile section */",
                        f"\t\t{build_id} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};")
    text = add_child(text, group_id, f"\t\t\t\t{ref_id} /* {name} */,")
    marker = (f"{RESOURCES_PHASE} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n"
              f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (")
    if marker not in text:
        raise SystemExit(f"resources phase {RESOURCES_PHASE} not found")
    return insert_after(text, marker, f"\t\t\t\t{build_id} /* {name} in Resources */,")
```

and in `main()`, right after `text, group_id = ensure_group(text, group_name)`:

```python
    if target == "resource-folder":
        for folder in files:
            text = add_resource_folder(text, group_id, folder)
        PROJECT.write_text(text)
        return
```

- [ ] **Step 2: Write the seed articles**

Each file below is complete; copy verbatim (the first one is plain Markdown despite the four-backtick wrapper). While copying, open every `sources` URL with WebFetch; if one no longer loads, replace it with the Apple Support page that covers the same topic and say so in the commit message.

`SpotlessMac/Resources/Knowledge/proc.spotlight-indexing.md`:

````markdown
---
id: proc.spotlight-indexing
kind: process
title: Spotlight индексирует диск (mds, mds_stores, mdworker)
summary: Индексация Spotlight. После обновления macOS или переноса данных может несколько часов нагружать процессор и диск — это нормально.
verdict: keep
aliases: [спотлайт, индексация, индексирование, поиск]
keywords: [нагрузка, процессор, cpu, вентилятор, тормозит]
processes: [mds, mds_stores, mdworker, mdworker_shared, corespotlightd]
related: [guide.slow-after-update, guide.spotlight-exclude]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://support.apple.com/guide/mac-help/search-with-spotlight-mchlp1008/mac, man:mdutil]
---
## Что это
Системные процессы поиска Spotlight. mds управляет индексом, mds_stores хранит его на диске, а mdworker и mdworker_shared читают новые и изменённые файлы, чтобы их можно было найти по имени и содержимому.

## Норма
В спокойном состоянии эти процессы почти незаметны. После обновления macOS, переноса данных на новый Mac, восстановления из резервной копии или подключения большого диска индексация может идти от нескольких часов до суток и заметно нагружать процессор и диск.

## Почему растёт
Нагрузка растёт, когда меняется много файлов сразу: распаковка архивов, сборка проектов, синхронизация облачных папок, большие загрузки.

## Что делать
Оставьте Mac включённым и подключённым к питанию — индексация закончится сама. Если какая-то папка не нужна в поиске (архив проектов, папка сборок, образы виртуальных машин), исключите её из индексации в настройках Spotlight. Нагрузку от этих процессов видно во вкладке «Память» SpotlessMac и в Мониторе системы.

## Чего не делать
Не завершайте эти процессы принудительно: система перезапустит их, и индексация продолжится или начнётся заново. Не удаляйте служебные папки индекса вручную.
````

`SpotlessMac/Resources/Knowledge/path.xcode-deriveddata.md`:

```markdown
---
id: path.xcode-deriveddata
kind: path
title: Xcode DerivedData — промежуточные файлы сборки
summary: Промежуточные результаты сборки и индексы Xcode. Удалять безопасно: Xcode создаст их заново при следующей сборке.
verdict: safe
aliases: [DerivedData, деривед дата, сборки xcode]
keywords: [xcode, кэш, сборка, индекс, разработка]
paths: [~/Library/Developer/Xcode/DerivedData]
related: [app.xcode, path.xcode-device-support, path.coresimulator]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://developer.apple.com/documentation/xcode]
---
## Что это
Папка, куда Xcode складывает промежуточные результаты сборки, индексы для автодополнения и поиска по коду, а также журналы сборок. Для каждого проекта создаётся своя подпапка.

## Норма
У активного разработчика DerivedData занимает от нескольких до десятков гигабайт. Подпапки старых и удалённых проектов остаются, пока их не удалить.

## Почему растёт
Каждый новый проект, ветка, конфигурация сборки и версия Xcode добавляют свои файлы. Сам Xcode старые данные не чистит.

## Что делать
Закройте Xcode и удалите DerivedData в разделе «Освободить место» во вкладке «Диск» — файлы уйдут в Корзину. Первая сборка и индексация проекта после очистки будут дольше обычного, затем всё вернётся в норму.

## Чего не делать
Не удаляйте папку во время сборки. Не путайте DerivedData с архивами (Archives): там лежат собранные версии приложений для публикации, и сами они не восстановятся.
```

`SpotlessMac/Resources/Knowledge/guide.memory-pressure.md`:

```markdown
---
id: guide.memory-pressure
kind: guide
title: Как читать давление памяти, сжатие и своп
summary: Занятая память — норма. Важен цвет давления: зелёный — порядок, жёлтый — на пределе, красный — пора закрыть тяжёлые программы.
verdict: info
aliases: [давление памяти, оперативная память, оперативка, ram, озу]
keywords: [своп, сжатие, сжатая, память, тормозит, нехватка, монитор системы]
related: [guide.high-swap, guide.no-ram-cleaners, guide.browser-memory]
macOS: 14-26
reviewed: 2026-10-03
sources: [https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac]
---
## Что это
macOS старается использовать почти всю оперативную память: свободная память ничего не ускоряет. Поэтому показатель «занято» сам по себе мало что говорит. Главный индикатор — давление памяти, которое SpotlessMac показывает во вкладке «Память» (то же, что график в Мониторе системы).

## Норма
Зелёное давление — памяти хватает, даже если занято почти всё. Сжатая память — нормальный механизм: система сжимает данные неактивных программ, чтобы не обращаться к диску.

## Почему растёт
Давление растёт, когда открытым программам нужно больше памяти, чем есть: много вкладок браузера, виртуальные машины и Docker, тяжёлые редакторы видео и фото, локальные модели ИИ. Тогда система чаще сжимает данные и начинает использовать своп — файл подкачки на диске.

## Что делать
При жёлтом давлении посмотрите во вкладке «Память», какие программы занимают больше всего, и закройте ненужные: лишние вкладки, программы, работающие в фоне. При красном давлении закройте самые тяжёлые программы. Если Mac давно не перезагружался и своп большой, перезагрузка поможет быстрее всего.

## Чего не делать
Не пользуйтесь программами, которые обещают «очистить оперативную память»: система сама управляет памятью, а принудительная очистка только замедлит работу. Не удаляйте файл подкачки — он освобождается сам.
```

- [ ] **Step 3: Register the folder and check it is copied into the app**

```bash
scripts/xcodeproj-add.py resource-folder Resources SpotlessMac/Resources/Knowledge
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" \
  -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO | tail -3
ls build/DerivedData/Build/Products/Debug/SpotlessMac.app/Contents/Resources/Knowledge
```

Expected: `** BUILD SUCCEEDED **` and the three `.md` files listed.

- [ ] **Step 4: Write the failing base and corpus tests**

Append to `SpotlessMacTests/KnowledgeFixtures.swift` inside `enum KnowledgeFixtures`:

```swift
    static func base(_ articles: [KnowledgeArticle]) -> KnowledgeBase {
        KnowledgeBase(articles: articles)
    }
```

`SpotlessMacTests/KnowledgeBaseTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class KnowledgeBaseTests: XCTestCase {
    private func text(_ id: String, kind: String = "guide", verdict: String = "info") -> String {
        "---\nid: \(id)\nkind: \(kind)\ntitle: \(id)\nsummary: Кратко.\nverdict: \(verdict)\nreviewed: 2026-10-03\n---\n"
            + KnowledgeFixtures.body
    }

    func testBuildSortsByIDAndLooksUp() {
        let (base, failures) = KnowledgeBase.build(files: [("guide.b.md", text("guide.b")), ("guide.a.md", text("guide.a"))])
        XCTAssertEqual(failures, [])
        XCTAssertEqual(base.articles.map(\.id), ["guide.a", "guide.b"])
        XCTAssertEqual(base.article(id: "guide.b")?.id, "guide.b")
        XCTAssertNil(base.article(id: "guide.c"))
        XCTAssertFalse(base.isEmpty)
    }

    func testBuildSkipsBrokenFilesAndKeepsTheRest() {
        let (base, failures) = KnowledgeBase.build(files: [
            ("guide.a.md", text("guide.a")),
            ("guide.broken.md", "no front matter"),
            ("guide.dup.md", text("guide.a")),
        ])
        XCTAssertEqual(base.articles.map(\.id), ["guide.a"])
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.contains { $0.hasPrefix("guide.broken.md:") })
        XCTAssertTrue(failures.contains { $0.hasPrefix("guide.dup.md:") })
    }

    func testEmptyBase() {
        XCTAssertTrue(KnowledgeBase.empty.isEmpty)
        XCTAssertEqual(KnowledgeBase.empty.search("кэш", limit: 3), [])
    }

    func testSearchGoesThroughTheIndex() {
        let base = KnowledgeFixtures.base([KnowledgeFixtures.article("guide.swap", title: "Своп")])
        XCTAssertEqual(base.search("своп", limit: 3).map(\.article.id), ["guide.swap"])
    }
}
```

`SpotlessMacTests/KnowledgeCorpusTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

// Lints the real articles in SpotlessMac/Resources/Knowledge. These rules keep the prompt text safe:
// nothing in the base may tell the model to run destructive commands or call protected folders safe.
final class KnowledgeCorpusTests: XCTestCase {
    static let wave1: Set<String> = [
        "proc.kernel-task", "proc.windowserver", "proc.spotlight-indexing", "proc.photos-analysis",
        "proc.icloud-sync", "proc.backupd", "proc.software-update", "proc.webkit", "proc.virtualization",
        "proc.dev-runtimes", "app.chrome", "app.electron", "app.docker", "app.telegram", "app.xcode",
        "path.user-caches", "path.logs", "path.xcode-deriveddata", "path.xcode-device-support", "path.coresimulator",
        "path.iphone-backups", "path.mobile-documents", "path.photos-library", "path.messages-attachments",
        "path.docker-raw", "path.package-caches", "path.ml-models", "path.project-artifacts", "path.old-installers",
        "path.trash", "path.swap",
        "guide.system-data", "guide.space-not-freed", "guide.memory-pressure", "guide.high-swap",
        "guide.no-ram-cleaners", "guide.slow-after-update", "guide.browser-memory", "guide.login-items",
        "guide.downloads-cleanup", "guide.desktop-organization", "guide.file-organization", "guide.optimize-storage",
        "guide.free-space-target", "guide.caches-explained", "guide.uninstall-apps", "guide.fda",
        "guide.spotlight-exclude", "guide.large-media",
    ]
    static let forbiddenWords = [
        "sudo", "rm", "kill", "killall", "pkill", "launchctl unload", "launchctl bootout", "launchctl remove",
        "defaults write", "defaults delete", "csrutil", "purge", "diskutil erase", "tmutil delete",
    ]
    static let bodyLength = 400...2_500

    static var sourceFiles: [(name: String, text: String)] {
        get throws {
            let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "SpotlessMac/Resources/Knowledge")
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                .filter { $0.hasSuffix(".md") }
                .sorted()
            return try names.map { ($0, try String(contentsOf: folder.appending(path: $0), encoding: .utf8)) }
        }
    }

    func corpus() throws -> KnowledgeBase {
        let (base, failures) = KnowledgeBase.build(files: try Self.sourceFiles)
        XCTAssertEqual(failures, [])
        return base
    }

    func testEveryArticleParses() throws {
        let files = try Self.sourceFiles
        XCTAssertFalse(files.isEmpty)
        let (base, failures) = KnowledgeBase.build(files: files)
        XCTAssertEqual(failures, [])
        XCTAssertEqual(base.articles.count, files.count)
    }

    func testBundledCopyMatchesSources() throws {
        // Unit tests run inside the app (TEST_HOST), so Bundle.main is SpotlessMac.app.
        let bundled = KnowledgeBase.loadBundled(from: .main)
        XCTAssertEqual(bundled.articles.map(\.id), try corpus().articles.map(\.id))
    }

    func testBodyLengthAndSources() throws {
        for article in try corpus().articles {
            XCTAssertTrue(Self.bodyLength.contains(article.body.count), "\(article.id): body \(article.body.count) chars")
            if article.kind != .guide { XCTAssertFalse(article.sources.isEmpty, "\(article.id): no sources") }
            for source in article.sources {
                XCTAssertTrue(source.hasPrefix("https://") || source.hasPrefix("man:"), "\(article.id): \(source)")
            }
        }
    }

    func testRelatedPointToKnownArticles() throws {
        let base = try corpus()
        let known = Set(base.articles.map(\.id)).union(Self.wave1)
        for article in base.articles {
            for id in article.related {
                XCTAssertTrue(known.contains(id), "\(article.id) → unknown \(id)")
                XCTAssertNotEqual(id, article.id)
            }
        }
    }

    func testBindingsMatchKind() throws {
        for article in try corpus().articles {
            switch article.kind {
            case .process:
                XCTAssertFalse(article.processes.isEmpty, "\(article.id): process without process names")
                XCTAssertTrue(article.paths.isEmpty, "\(article.id): process articles carry no paths")
            case .app:
                XCTAssertFalse(article.bundles.isEmpty, "\(article.id): app without bundle IDs")
                XCTAssertTrue(article.paths.isEmpty, "\(article.id): app articles carry no paths")
            case .path:
                XCTAssertFalse(article.paths.isEmpty && article.categories.isEmpty, "\(article.id): unbound path article")
                XCTAssertTrue(article.processes.isEmpty && article.bundles.isEmpty, "\(article.id)")
            case .guide:
                XCTAssertTrue(article.processes.isEmpty && article.bundles.isEmpty && article.paths.isEmpty, "\(article.id)")
                XCTAssertEqual(article.verdict, .info, "\(article.id): guides use verdict info")
            }
        }
    }

    func testNoForbiddenWords() throws {
        for article in try corpus().articles {
            let text = [article.title, article.summary, article.body].joined(separator: "\n")
            for word in Self.forbiddenWords {
                let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}_])"#
                XCTAssertNil(text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                             "\(article.id) contains «\(word)»")
            }
        }
    }

    // The assistant never suggests terminal commands (AssistantGuard hides them in answers anyway),
    // so articles carry none: no code fences, no command lines, no commands in inline code.
    func testNoCodeOrTerminalCommands() throws {
        for article in try corpus().articles {
            for line in article.body.components(separatedBy: "\n") {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("```"), "\(article.id): code fence")
                XCTAssertFalse(AssistantGuard.looksLikeCommand(line), "\(article.id): command line «\(line)»")
            }
            for span in article.body.matches(of: /`([^`\n]+)`/).map({ String($0.1) }) {
                XCTAssertFalse(AssistantGuard.looksLikeCommand(span), "\(article.id): inline command «\(span)»")
            }
        }
    }
}
```

- [ ] **Step 5: Register and run to see them fail**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeBaseTests.swift SpotlessMacTests/KnowledgeCorpusTests.swift
scripts/test.sh KnowledgeBaseTests KnowledgeCorpusTests
```

Expected: build error `cannot find 'KnowledgeBase' in scope`.

- [ ] **Step 6: Implement**

`SpotlessMac/Assistant/KnowledgeBase.swift`:

```swift
import Foundation
import os

// The bundled, read-only knowledge base. Loaded once at launch and handed to the assistant as a value.
struct KnowledgeBase: Sendable {
    static let empty = KnowledgeBase(articles: [])
    static let resourceFolder = "Knowledge"
    private static let logger = Logger(subsystem: "com.spotlessmac.app", category: "knowledge")

    let articles: [KnowledgeArticle]
    private let byID: [String: KnowledgeArticle]
    private let index: KnowledgeSearch

    init(articles: [KnowledgeArticle]) {
        let sorted = articles.sorted { $0.id < $1.id }
        self.articles = sorted
        byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        index = KnowledgeSearch(articles: sorted)
    }

    var isEmpty: Bool { articles.isEmpty }

    func article(id: String) -> KnowledgeArticle? { byID[id] }

    func search(_ query: String, limit: Int) -> [KnowledgeHit] { index.search(query, limit: limit) }

    // Parses every file. A file that fails (or repeats an id) is reported and skipped; the rest still load.
    static func build(files: [(name: String, text: String)]) -> (base: KnowledgeBase, failures: [String]) {
        var articles: [KnowledgeArticle] = []
        var seen = Set<String>()
        var failures: [String] = []
        for file in files.sorted(by: { $0.name < $1.name }) {
            do {
                let article = try KnowledgeParser.parse(file.text, fileName: file.name)
                guard seen.insert(article.id).inserted else {
                    failures.append("\(file.name): duplicate id \(article.id)")
                    continue
                }
                articles.append(article)
            } catch {
                failures.append("\(file.name): \(error)")
            }
        }
        return (KnowledgeBase(articles: articles), failures)
    }

    static func loadBundled(from bundle: Bundle) -> KnowledgeBase {
        let urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: resourceFolder) ?? []
        // An unreadable file is passed on as empty text, so it is reported as a parse failure below.
        let files = urls.map { url in (name: url.lastPathComponent, text: (try? String(contentsOf: url, encoding: .utf8)) ?? "") }
        let (base, failures) = build(files: files)
        if base.isEmpty { logger.error("Knowledge base is empty: no articles in the bundle") }
        for failure in failures { logger.error("Knowledge article skipped: \(failure, privacy: .public)") }
        assert(failures.isEmpty, "Broken knowledge articles: \(failures)")
        return base
    }
}
```

- [ ] **Step 7: Register and run**

```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/KnowledgeBase.swift
scripts/test.sh KnowledgeBaseTests KnowledgeCorpusTests KnowledgeParserTests AssistantIsolationTests
```

Expected: PASS. If `testBodyLengthAndSources`, `testNoForbiddenWords` or `testNoCodeOrTerminalCommands` fails on a seed article, fix the article text, not the rule.

- [ ] **Step 8: Commit**

```bash
git add scripts/xcodeproj-add.py SpotlessMac/Assistant/KnowledgeBase.swift SpotlessMac/Resources/Knowledge \
  SpotlessMacTests/KnowledgeFixtures.swift SpotlessMacTests/KnowledgeBaseTests.swift SpotlessMacTests/KnowledgeCorpusTests.swift \
  SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(knowledge): bundled knowledge base, seed articles and corpus lint

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Retrieval evaluation harness

**Files:**
- Create: `SpotlessMacTests/KnowledgeEvalTests.swift`
- Create: `SpotlessMacTests/Fixtures/knowledge-eval-seed.json`

**Interfaces:**
- Consumes: `KnowledgeCorpusTests.sourceFiles`, `KnowledgeBase.build`, `KnowledgeBase.search` (Task 3).
- Produces: eval file convention `SpotlessMacTests/Fixtures/knowledge-eval-<batch>.json`, an array of `{"query": String, "expected": String}`; every file matching `knowledge-eval-*.json` is loaded. Content tasks add their own file.

- [ ] **Step 1: Write the eval file**

`SpotlessMacTests/Fixtures/knowledge-eval-seed.json`:

```json
[
  {"query": "что за процесс mds_stores грузит процессор", "expected": "proc.spotlight-indexing"},
  {"query": "mdworker_shared ест cpu", "expected": "proc.spotlight-indexing"},
  {"query": "идёт индексация после обновления", "expected": "proc.spotlight-indexing"},
  {"query": "можно ли удалить DerivedData", "expected": "path.xcode-deriveddata"},
  {"query": "xcode сборки занимают много места", "expected": "path.xcode-deriveddata"},
  {"query": "что значит жёлтое давление памяти", "expected": "guide.memory-pressure"},
  {"query": "оперативка занята почти вся это плохо", "expected": "guide.memory-pressure"},
  {"query": "сжатая память что это", "expected": "guide.memory-pressure"}
]
```

- [ ] **Step 2: Write the eval test**

`SpotlessMacTests/KnowledgeEvalTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

// Retrieval quality gate: real user questions must find the expected article in the top 3.
// Each content batch adds SpotlessMacTests/Fixtures/knowledge-eval-<batch>.json.
final class KnowledgeEvalTests: XCTestCase {
    struct EvalCase: Decodable {
        let query: String
        let expected: String
    }

    static let threshold = 0.9

    private func cases() throws -> [EvalCase] {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("knowledge-eval-") && $0.hasSuffix(".json") }
            .sorted()
        var result: [EvalCase] = []
        for name in names {
            result += try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: folder.appending(path: name)))
        }
        return result
    }

    func testEvalQueriesFindTheExpectedArticleInTopThree() throws {
        let cases = try cases()
        XCTAssertFalse(cases.isEmpty)
        let (base, failures) = KnowledgeBase.build(files: try KnowledgeCorpusTests.sourceFiles)
        XCTAssertEqual(failures, [])
        var misses: [String] = []
        for test in cases {
            XCTAssertNotNil(base.article(id: test.expected), "eval expects unknown article \(test.expected)")
            let top = base.search(test.query, limit: 3).map(\.article.id)
            if !top.contains(test.expected) { misses.append("«\(test.query)» → \(test.expected), got \(top)") }
        }
        let rate = Double(cases.count - misses.count) / Double(cases.count)
        print("Knowledge eval: \(cases.count - misses.count)/\(cases.count) in top 3")
        for miss in misses { print("  miss: \(miss)") }
        XCTAssertGreaterThanOrEqual(rate, Self.threshold, misses.joined(separator: "\n"))
    }
}
```

- [ ] **Step 3: Register and run**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeEvalTests.swift
scripts/test.sh KnowledgeEvalTests
```

Expected: PASS, output contains `Knowledge eval: 8/8 in top 3` (with three articles every scored article is in the top 3; the gate becomes meaningful as content lands).

- [ ] **Step 4: Commit**

```bash
git add SpotlessMacTests/KnowledgeEvalTests.swift SpotlessMacTests/Fixtures/knowledge-eval-seed.json SpotlessMac.xcodeproj/project.pbxproj
git commit -m "test(knowledge): retrieval evaluation harness

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Snapshot memory data for matching

**Files:**
- Modify: `SpotlessMac/Assistant/SystemSnapshot.swift` (`MemoryAppInfo`, new `MemoryProcessInfo`, `MemoryInfo`)
- Modify: `SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift:51-69` (`memoryInfo`)
- Test: `SpotlessMacTests/AssistantStagingTests.swift`

**Interfaces:**
- Consumes: `MemorySample`, `AppMemoryGroup.Kind`, `MemorySample.runningApps(in:)`, `ProcessMemorySample.name/footprint/pid`.
- Produces:
  - `struct MemoryAppInfo: Equatable, Sendable { let name: String; let bytes: Int64; var bundleID: String? = nil }`
  - `struct MemoryProcessInfo: Equatable, Sendable { let name: String; let bytes: Int64 }`
  - `MemoryInfo.topProcesses: [MemoryProcessInfo]` (default `[]`)
  - `AssistantSnapshotBuilder.maxTopProcesses = 8`

- [ ] **Step 1: Write the failing tests** (append to `AssistantStagingTests`)

```swift
    func testMemoryInfoCarriesBundleIDsAndTopProcesses() {
        let chrome = MemoryFixtures.userGroup("/Applications/Google Chrome.app",
                                              processes: [MemoryFixtures.process(10, footprint: 3 << 30)])
        let system = AppMemoryGroup(id: ProcessGrouper.systemGroupID, displayName: "Система", kind: .system, bundlePath: nil,
                                    processes: [MemoryFixtures.process(0, name: "kernel_task", footprint: 2 << 30),
                                                MemoryFixtures.process(90, name: "WindowServer", footprint: 1 << 30)])
        let other = AppMemoryGroup(id: "other:node", displayName: "node", kind: .other, bundlePath: nil,
                                   processes: [MemoryFixtures.process(300, name: "node", footprint: 3 << 29)])
        let sample = MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [chrome, system, other],
                                           runningApps: [MemoryFixtures.app(10, "/Applications/Google Chrome.app", id: "com.google.Chrome")])
        let info = AssistantSnapshotBuilder.memoryInfo(sample)
        XCTAssertEqual(info.topApps, [MemoryAppInfo(name: "Google Chrome", bytes: 3 << 30, bundleID: "com.google.Chrome")])
        XCTAssertEqual(info.topProcesses.map(\.name), ["kernel_task", "node", "WindowServer"])
        XCTAssertEqual(info.topProcesses.first?.bytes, 2 << 30)
    }

    func testTopProcessesAreCapped() {
        let processes = (1...12).map { MemoryFixtures.process(pid_t($0), name: "p\($0)", footprint: UInt64($0) << 20) }
        let system = AppMemoryGroup(id: ProcessGrouper.systemGroupID, displayName: "Система", kind: .system,
                                    bundlePath: nil, processes: processes)
        let info = AssistantSnapshotBuilder.memoryInfo(MemoryFixtures.sample(at: SystemSnapshot.testDate, groups: [system]))
        XCTAssertEqual(info.topProcesses.count, AssistantSnapshotBuilder.maxTopProcesses)
        XCTAssertEqual(info.topProcesses.first?.name, "p12")
        XCTAssertNil(info.topApps.first?.bundleID)
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `scripts/test.sh AssistantStagingTests`
Expected: build error `extra argument 'bundleID' in call` / `value of type 'MemoryInfo' has no member 'topProcesses'`.

- [ ] **Step 3: Implement**

In `SystemSnapshot.swift` replace `MemoryAppInfo` and extend `MemoryInfo`:

```swift
struct MemoryAppInfo: Equatable, Sendable {
    let name: String
    let bytes: Int64
    var bundleID: String? = nil
}

// A process outside user apps (system service, script) — shown so knowledge articles can be bound to it.
struct MemoryProcessInfo: Equatable, Sendable {
    let name: String
    let bytes: Int64
}

// Read-only memory context. Quitting apps is never available to the assistant.
struct MemoryInfo: Equatable, Sendable {
    let load: MemoryLoad
    let usedBytes: Int64
    let physicalBytes: Int64
    let swapUsedBytes: Int64
    let topApps: [MemoryAppInfo]
    var topProcesses: [MemoryProcessInfo] = []
}
```

In `AssistantSnapshotBuilder`, add `static let maxTopProcesses = 8` at the top of the enum and replace the body of `memoryInfo(_:)` after the `load` switch:

```swift
        let topApps = sample.groups
            .filter { $0.kind == .userApp }
            .sorted { $0.footprint > $1.footprint }
            .prefix(5)
            .map { group in
                MemoryAppInfo(name: group.displayName, bytes: Int64(clamping: group.footprint),
                              bundleID: sample.runningApps(in: group).compactMap(\.bundleIdentifier).first)
            }
        let topProcesses = sample.groups
            .filter { $0.kind != .userApp }
            .flatMap(\.processes)
            .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
            .prefix(maxTopProcesses)
            .map { MemoryProcessInfo(name: $0.name, bytes: Int64(clamping: $0.footprint)) }
        return MemoryInfo(
            load: load,
            usedBytes: Int64(clamping: sample.system.used),
            physicalBytes: Int64(clamping: sample.system.physical),
            swapUsedBytes: Int64(clamping: sample.system.swapUsed),
            topApps: Array(topApps),
            topProcesses: Array(topProcesses)
        )
```

- [ ] **Step 4: Run**

Run: `scripts/test.sh AssistantStagingTests SnapshotRendererTests AssistantViewModelTests`
Expected: PASS (existing `testMemoryInfoKeepsTopUserAppsOnly` still passes).

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/SystemSnapshot.swift SpotlessMac/ViewModels/AssistantSnapshotBuilder.swift SpotlessMacTests/AssistantStagingTests.swift
git commit -m "feat(assistant): bundle IDs and top system processes in the memory snapshot

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Matcher (bind articles to items, apps, processes)

**Files:**
- Create: `SpotlessMac/Assistant/KnowledgeMatcher.swift`
- Create: `SpotlessMacTests/KnowledgeMatcherTests.swift`
- Modify: `SpotlessMacTests/KnowledgeCorpusTests.swift` (two new lint tests)

**Interfaces:**
- Consumes: `KnowledgeBase`, `SystemSnapshot`, `MemoryAppInfo.bundleID`, `MemoryInfo.topProcesses` (Tasks 3, 5).
- Produces:
  - `struct KnowledgeAnnotations: Equatable, Sendable { var items: [String: String] /* shortID → article id */; var apps: [String: String] /* app name → id */; var processes: [String: String] /* process name → id */; var isEmpty: Bool }`
  - `struct KnowledgeContext: Sendable { static let none; let base: KnowledgeBase; let annotations: KnowledgeAnnotations }`
  - `enum KnowledgeMatcher { static func annotate(_:knowledge:homePath:) -> KnowledgeAnnotations; static func article(forPath:category:in:homePath:) -> KnowledgeArticle?; static func article(forApp:bundleID:in:) -> KnowledgeArticle?; static func article(forProcess:in:) -> KnowledgeArticle?; static func specificity(of:matching:homePath:) -> Int? }`

- [ ] **Step 1: Write the failing matcher tests**

`SpotlessMacTests/KnowledgeMatcherTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class KnowledgeMatcherTests: XCTestCase {
    private let home = SystemSnapshot.testHome

    private func base() -> KnowledgeBase {
        KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.user-caches", kind: .path, verdict: .safe, paths: ["~/Library/Caches"],
                                      categories: [.userCaches]),
            KnowledgeFixtures.article("path.package-caches", kind: .path, verdict: .safe, paths: ["~/Library/Caches/Homebrew"],
                                      categories: [.developerCaches]),
            KnowledgeFixtures.article("path.containers", kind: .path, verdict: .caution, paths: ["~/Library/Containers/*/Data"]),
            KnowledgeFixtures.article("path.docker-raw", kind: .path, verdict: .caution,
                                      paths: ["~/Library/Containers/com.docker.docker/Data"]),
            KnowledgeFixtures.article("path.photos-library", kind: .path, verdict: .keep, paths: ["~/Pictures/*.photoslibrary"]),
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, verdict: .safe,
                                      paths: ["~/Library/Developer/Xcode/DerivedData"]),
            KnowledgeFixtures.article("app.xcode", kind: .app, verdict: .caution, aliases: ["Xcode"], bundles: ["com.apple.dt.Xcode"]),
            KnowledgeFixtures.article("app.chrome", kind: .app, verdict: .safe, aliases: ["Google Chrome"], bundles: ["com.google.Chrome"]),
            KnowledgeFixtures.article("guide.chrome-tips", aliases: ["Chrome Tips"]),
            KnowledgeFixtures.article("proc.kernel-task", kind: .process, verdict: .keep, processes: ["kernel_task"]),
        ])
    }

    func testPatternCoversThePathAndItsContentsOnly() {
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/Caches", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/Caches/x/y", homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library", homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Library/Caches", matching: home + "/Library/CachesX", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "/private/var/vm", matching: "/private/var/vm/swapfile0", homePath: home))
    }

    func testWildcardMatchesInsideOneComponent() {
        let library = home + "/Pictures/Photos Library.photoslibrary/originals"
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Pictures/*.photoslibrary", matching: library, homePath: home))
        XCTAssertNil(KnowledgeMatcher.specificity(of: "~/Pictures/*.photoslibrary", matching: home + "/Pictures/a.jpg", homePath: home))
        XCTAssertNotNil(KnowledgeMatcher.specificity(of: "~/Library/Containers/*/Data",
                                                     matching: home + "/Library/Containers/com.x/Data/y", homePath: home))
    }

    func testMostSpecificPatternWins() {
        let article = KnowledgeMatcher.article(forPath: home + "/Library/Caches/Homebrew/downloads", category: .userCaches,
                                               in: base(), homePath: home)
        XCTAssertEqual(article?.id, "path.package-caches")
    }

    func testLiteralBeatsWildcard() {
        let article = KnowledgeMatcher.article(forPath: home + "/Library/Containers/com.docker.docker/Data/vms",
                                               category: nil, in: base(), homePath: home)
        XCTAssertEqual(article?.id, "path.docker-raw")
    }

    func testCategoryFallbackAndNoMatch() {
        XCTAssertEqual(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: .developerCaches,
                                                in: base(), homePath: home)?.id, "path.package-caches")
        XCTAssertNil(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: .trash, in: base(), homePath: home))
        XCTAssertNil(KnowledgeMatcher.article(forPath: "/opt/tool/cache", category: nil, in: base(), homePath: home))
    }

    func testAppsMatchByBundleThenByAppAlias() {
        XCTAssertEqual(KnowledgeMatcher.article(forApp: "Хром", bundleID: "com.google.Chrome", in: base())?.id, "app.chrome")
        XCTAssertEqual(KnowledgeMatcher.article(forApp: "google chrome", bundleID: nil, in: base())?.id, "app.chrome")
        XCTAssertNil(KnowledgeMatcher.article(forApp: "Chrome Tips", bundleID: nil, in: base()), "guides never bind to apps")
        XCTAssertNil(KnowledgeMatcher.article(forApp: "Slack", bundleID: "com.tinyspeck.slackmacgap", in: base()))
    }

    func testProcessesMatchByExactName() {
        XCTAssertEqual(KnowledgeMatcher.article(forProcess: "kernel_task", in: base())?.id, "proc.kernel-task")
        XCTAssertNil(KnowledgeMatcher.article(forProcess: "kernel", in: base()))
    }

    func testAnnotateSnapshot() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory = MemoryInfo(load: .normal, usedBytes: 1, physicalBytes: 2, swapUsedBytes: 0,
                                     topApps: [MemoryAppInfo(name: "Xcode", bytes: 4, bundleID: "com.apple.dt.Xcode"),
                                               MemoryAppInfo(name: "Telegram", bytes: 1)],
                                     topProcesses: [MemoryProcessInfo(name: "kernel_task", bytes: 3),
                                                    MemoryProcessInfo(name: "node", bytes: 2)])
        let annotations = KnowledgeMatcher.annotate(snapshot, knowledge: base(), homePath: home)
        XCTAssertEqual(annotations.items["c1"], "path.xcode-deriveddata")
        XCTAssertEqual(annotations.items["c3"], "path.user-caches")
        XCTAssertNil(annotations.items["c2"])
        XCTAssertEqual(annotations.apps, ["Xcode": "app.xcode"])
        XCTAssertEqual(annotations.processes, ["kernel_task": "proc.kernel-task"])
    }

    func testEmptyBaseAnnotatesNothing() {
        XCTAssertTrue(KnowledgeMatcher.annotate(.sample(), knowledge: .empty, homePath: home).isEmpty)
    }
}
```

(Sample snapshot items: `c1` DerivedData, `c2` `~/Projects/secret-client/node_modules` (`project_artifacts`, no article in this base), `c3` `~/Library/Caches/com.spotify.client`.)

Append to `KnowledgeCorpusTests`:

```swift
    static let protectedRoots = [
        "/System", "/private/var/vm", "~/Pictures/Photos Library.photoslibrary", "~/Library/Mobile Documents",
        "~/Library/Messages", "~/Library/Application Support/MobileSync/Backup",
    ]

    func testSafeArticlesNeverCoverProtectedRoots() throws {
        let base = try corpus()
        let home = "/Users/tester"
        for root in Self.protectedRoots {
            let path = root.hasPrefix("~/") ? home + root.dropFirst() : root
            for probe in [path, path + "/inner"] {
                guard let article = KnowledgeMatcher.article(forPath: probe, category: nil, in: base, homePath: home) else { continue }
                XCTAssertNotEqual(article.verdict, .safe, "\(article.id) calls \(probe) safe")
            }
        }
    }

    func testBindingKeysAreUnique() throws {
        var owners: [String: String] = [:]
        for article in try corpus().articles {
            for key in article.processes.map({ "process:" + $0 }) + article.bundles.map({ "bundle:" + $0 })
                + article.paths.map({ "path:" + $0 }) {
                if let other = owners[key] { XCTFail("\(key) bound by both \(other) and \(article.id)") }
                owners[key] = article.id
            }
        }
    }
```

- [ ] **Step 2: Register and run to see them fail**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeMatcherTests.swift
scripts/test.sh KnowledgeMatcherTests
```

Expected: build error `cannot find 'KnowledgeMatcher' in scope`.

- [ ] **Step 3: Implement**

`SpotlessMac/Assistant/KnowledgeMatcher.swift`:

```swift
import Foundation

// Article ids bound to what the snapshot shows: scanned items by short ID, memory apps and processes by name.
struct KnowledgeAnnotations: Equatable, Sendable {
    var items: [String: String] = [:]
    var apps: [String: String] = [:]
    var processes: [String: String] = [:]

    var isEmpty: Bool { items.isEmpty && apps.isEmpty && processes.isEmpty }
}

// Everything the renderer and the toolbox need from the knowledge base for one answer.
struct KnowledgeContext: Sendable {
    static let none = KnowledgeContext(base: .empty, annotations: KnowledgeAnnotations())

    let base: KnowledgeBase
    let annotations: KnowledgeAnnotations
}

// Binds snapshot entities to articles. Runs on real (unredacted) paths; only article ids leave this type.
enum KnowledgeMatcher {
    static func annotate(_ snapshot: SystemSnapshot, knowledge: KnowledgeBase, homePath: String) -> KnowledgeAnnotations {
        guard !knowledge.isEmpty else { return KnowledgeAnnotations() }
        var result = KnowledgeAnnotations()
        for item in snapshot.items {
            if let article = article(forPath: item.path, category: item.category, in: knowledge, homePath: homePath) {
                result.items[item.shortID] = article.id
            }
        }
        for app in snapshot.memory?.topApps ?? [] {
            if let article = article(forApp: app.name, bundleID: app.bundleID, in: knowledge) {
                result.apps[app.name] = article.id
            }
        }
        for process in snapshot.memory?.topProcesses ?? [] {
            if let article = article(forProcess: process.name, in: knowledge) {
                result.processes[process.name] = article.id
            }
        }
        return result
    }

    // The most specific path pattern wins; without one, the article that is the fallback for the category.
    static func article(forPath path: String, category: ScanCategory?, in knowledge: KnowledgeBase,
                        homePath: String) -> KnowledgeArticle? {
        var best: (article: KnowledgeArticle, score: Int)?
        for article in knowledge.articles {
            for pattern in article.paths {
                guard let score = specificity(of: pattern, matching: path, homePath: homePath) else { continue }
                if score > (best?.score ?? Int.min) { best = (article, score) }
            }
        }
        if let best { return best.article }
        guard let category else { return nil }
        return knowledge.articles.first { $0.categories.contains(category) }
    }

    static func article(forApp name: String, bundleID: String?, in knowledge: KnowledgeBase) -> KnowledgeArticle? {
        if let bundleID, let article = knowledge.articles.first(where: { $0.bundles.contains(bundleID) }) {
            return article
        }
        let lowered = name.lowercased()
        return knowledge.articles.first { article in
            article.kind == .app
                && (article.title.lowercased() == lowered || article.aliases.contains { $0.lowercased() == lowered })
        }
    }

    static func article(forProcess name: String, in knowledge: KnowledgeBase) -> KnowledgeArticle? {
        knowledge.articles.first { $0.processes.contains(name) }
    }

    // nil when `pattern` does not cover `path` (the path itself or anything inside it). Otherwise a score:
    // more components rank higher, then more literal components. `~` is the home folder; one `*` inside a
    // component matches any run of characters within that component.
    static func specificity(of pattern: String, matching path: String, homePath: String) -> Int? {
        let expanded = pattern == "~" ? homePath : pattern.hasPrefix("~/") ? homePath + pattern.dropFirst() : pattern
        let patternParts = expanded.split(separator: "/")
        let pathParts = path.split(separator: "/")
        guard !patternParts.isEmpty, pathParts.count >= patternParts.count else { return nil }
        var literals = 0
        for (patternPart, pathPart) in zip(patternParts, pathParts) {
            guard componentMatches(patternPart, pathPart) else { return nil }
            if !patternPart.contains("*") { literals += 1 }
        }
        return patternParts.count * 100 + literals
    }

    private static func componentMatches(_ pattern: Substring, _ component: Substring) -> Bool {
        guard pattern.contains("*") else { return pattern == component }
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return component.count >= pieces[0].count + pieces[1].count
            && component.hasPrefix(pieces[0]) && component.hasSuffix(pieces[1])
    }
}
```

- [ ] **Step 4: Register and run**

```bash
scripts/xcodeproj-add.py app Assistant SpotlessMac/Assistant/KnowledgeMatcher.swift
scripts/test.sh KnowledgeMatcherTests KnowledgeCorpusTests AssistantIsolationTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add SpotlessMac/Assistant/KnowledgeMatcher.swift SpotlessMacTests/KnowledgeMatcherTests.swift \
  SpotlessMacTests/KnowledgeCorpusTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(knowledge): bind articles to scanned paths, apps and processes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Rendering (article text, section, «справка» column)

**Files:**
- Create: `SpotlessMac/Assistant/KnowledgeRenderer.swift`
- Create: `SpotlessMacTests/KnowledgeRendererTests.swift`
- Modify: `SpotlessMac/Assistant/SnapshotRenderer.swift` (`render`, `itemLine`, `itemCard`, memory lines)
- Modify: `SpotlessMac/Assistant/AssistantToolbox.swift` (call sites of `itemLine`/`itemCard` keep compiling via defaults; header text updated in Task 8)
- Test: `SpotlessMacTests/SnapshotRendererTests.swift`

**Interfaces:**
- Consumes: `KnowledgeContext`, `KnowledgeAnnotations` (Task 6); `MemoryInfo.topProcesses` (Task 5).
- Produces:
  - `enum KnowledgeRenderer { static let articleLimit = 3_000, lookupLimit = 6_000, sectionLimit = 2_500, sectionEntries = 12, injectedLimit = 4_000; static func article(_:limit:) -> String; static func lookup(id: String?, query: String?, in: KnowledgeBase) -> String; static func injected(for question: String, in: KnowledgeBase) -> String?; static func section(_ snapshot: SystemSnapshot, context: KnowledgeContext) -> String? }`
  - `SnapshotRenderer.render(_ snapshot:, knowledge: KnowledgeContext = .none, formatPath:)`
  - `SnapshotRenderer.itemLine(_ item:, articleID: String? = nil, formatPath:)`, `SnapshotRenderer.itemCard(_ item:, articleID: String? = nil, formatPath:)`
  - `SnapshotRenderer.itemColumns = "ID | путь | размер | категория | политика | изменён | владелец | справка"`

- [ ] **Step 1: Write the failing tests**

`SpotlessMacTests/KnowledgeRendererTests.swift`:

```swift
import XCTest
@testable import SpotlessMac

final class KnowledgeRendererTests: XCTestCase {
    private let swap = KnowledgeFixtures.article("guide.swap", title: "Своп", summary: "Файл подкачки.",
                                                 related: ["guide.memory"])
    private let memory = KnowledgeFixtures.article("guide.memory", title: "Давление памяти", summary: "Как читать.")

    func testArticleText() {
        let text = KnowledgeRenderer.article(swap)
        XCTAssertTrue(text.hasPrefix("[guide.swap] Своп\nВердикт: справка\nКратко: Файл подкачки.\n## Что это"))
        XCTAssertTrue(text.hasSuffix("См. также: guide.memory"))
    }

    func testArticleIsTruncated() {
        let long = KnowledgeFixtures.article("guide.long", body: String(repeating: "а", count: 5_000))
        let text = KnowledgeRenderer.article(long)
        XCTAssertEqual(text.count, KnowledgeRenderer.articleLimit)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testLookupByIDAndQuery() {
        let base = KnowledgeFixtures.base([swap, memory])
        XCTAssertTrue(KnowledgeRenderer.lookup(id: "guide.swap", query: nil, in: base).hasPrefix("[guide.swap]"))
        let byQuery = KnowledgeRenderer.lookup(id: nil, query: "давление памяти", in: base)
        XCTAssertTrue(byQuery.hasPrefix("Найдено в справке: "))
        XCTAssertTrue(byQuery.contains("[guide.memory]"))
    }

    func testLookupUnknownIDSuggestsSimilar() {
        let base = KnowledgeFixtures.base([swap, memory])
        let text = KnowledgeRenderer.lookup(id: "guide.memory-pressure", query: nil, in: base)
        XCTAssertTrue(text.hasPrefix("Статья guide.memory-pressure не найдена. Похожие статьи: guide.memory — Давление памяти"))
    }

    func testLookupWithNothingFound() {
        let text = KnowledgeRenderer.lookup(id: nil, query: "zzzz", in: KnowledgeFixtures.base([swap]))
        XCTAssertEqual(text, "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет.")
    }

    func testLookupResultIsCapped() {
        let big = (1...3).map { KnowledgeFixtures.article("guide.big\($0)", title: "Кэш \($0)", body: String(repeating: "кэш ", count: 900)) }
        let text = KnowledgeRenderer.lookup(id: nil, query: "кэш", in: KnowledgeFixtures.base(big))
        XCTAssertLessThanOrEqual(text.count, KnowledgeRenderer.lookupLimit)
        XCTAssertTrue(text.contains("[guide.big1]"))
    }

    func testInjectedReference() {
        let base = KnowledgeFixtures.base([swap, memory])
        let text = KnowledgeRenderer.injected(for: "что такое своп", in: base)
        XCTAssertTrue(text?.hasPrefix("Справка SpotlessMac по вопросу:\n\n[guide.swap]") == true)
        XCTAssertNil(KnowledgeRenderer.injected(for: "zzzz", in: base))
        XCTAssertLessThanOrEqual(text?.count ?? 0, KnowledgeRenderer.injectedLimit)
    }

    func testSectionOrdersByCoveredBytesAndDeduplicates() {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.derived", kind: .path, summary: "Сборки.", verdict: .safe),
            KnowledgeFixtures.article("path.caches", kind: .path, summary: "Кэши.", verdict: .safe),
        ])
        let annotations = KnowledgeAnnotations(items: ["c1": "path.derived", "c3": "path.caches", "c5": "path.caches"])
        let text = KnowledgeRenderer.section(.sample(), context: KnowledgeContext(base: base, annotations: annotations))
        XCTAssertEqual(text, """
        Справка SpotlessMac по найденному (id — вердикт — кратко):
        - path.derived — безопасно — Сборки.
        - path.caches — безопасно — Кэши.
        """)
    }

    func testSectionIsCappedAndEmptyWithoutMatches() {
        XCTAssertNil(KnowledgeRenderer.section(.sample(), context: .none))
        let articles = (1...20).map {
            KnowledgeFixtures.article("guide.n\($0)", summary: String(repeating: "с", count: 150))
        }
        var items: [String: String] = [:]
        var snapshot = SystemSnapshot.sample()
        snapshot.items = (1...20).map { n in
            SnapshotItem(shortID: "c\(n)", itemID: UUID(), path: "/x/\(n)", bytes: Int64(100 - n), category: .userCaches,
                         disposition: .rebuildable, reason: "r", modifiedAt: nil, owner: nil)
        }
        for n in 1...20 { items["c\(n)"] = "guide.n\(n)" }
        let text = KnowledgeRenderer.section(snapshot, context: KnowledgeContext(base: KnowledgeFixtures.base(articles),
                                                                                  annotations: KnowledgeAnnotations(items: items)))
        let lines = text?.components(separatedBy: "\n") ?? []
        XCTAssertLessThanOrEqual(lines.count - 1, KnowledgeRenderer.sectionEntries)
        XCTAssertLessThanOrEqual(text?.count ?? 0, KnowledgeRenderer.sectionLimit)
    }
}
```

Append to `SnapshotRendererTests`:

```swift
    private func knowledgeContext() -> KnowledgeContext {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, summary: "Сборки Xcode.", verdict: .safe),
            KnowledgeFixtures.article("app.xcode", kind: .app, summary: "Xcode.", verdict: .caution),
            KnowledgeFixtures.article("proc.kernel-task", kind: .process, summary: "Ядро.", verdict: .keep),
        ])
        return KnowledgeContext(base: base, annotations: KnowledgeAnnotations(
            items: ["c1": "path.xcode-deriveddata"], apps: ["Xcode": "app.xcode"], processes: ["kernel_task": "proc.kernel-task"]))
    }

    func testItemLinesCarryTheArticleColumn() {
        let text = SnapshotRenderer.render(.sample(), knowledge: knowledgeContext()) { $0 }
        XCTAssertTrue(text.contains("(ID | путь | размер | категория | политика | изменён | владелец | справка):"))
        let c1 = text.components(separatedBy: "\n").first { $0.hasPrefix("c1 |") } ?? ""
        XCTAssertTrue(c1.hasSuffix("| path.xcode-deriveddata"), c1)
        let c2 = text.components(separatedBy: "\n").first { $0.hasPrefix("c2 |") } ?? ""
        XCTAssertTrue(c2.hasSuffix("| —"), c2)
    }

    func testMemoryLinesCarryArticleIDsAndTopProcesses() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory?.topProcesses = [MemoryProcessInfo(name: "kernel_task", bytes: 2_000_000_000),
                                         MemoryProcessInfo(name: "node", bytes: 1_000_000_000)]
        let text = SnapshotRenderer.render(snapshot, knowledge: knowledgeContext()) { $0 }
        XCTAssertTrue(text.contains("Xcode — \(SnapshotRenderer.memoryBytes(4_000_000_000)) [app.xcode]"))
        XCTAssertTrue(text.contains("Крупные процессы вне программ: kernel_task — \(SnapshotRenderer.memoryBytes(2_000_000_000)) [proc.kernel-task], node — "))
        XCTAssertTrue(text.contains("Справка SpotlessMac по найденному"))
        XCTAssertTrue(text.contains("- path.xcode-deriveddata — безопасно — Сборки Xcode."))
    }

    func testTopProcessNamesAreFormatted() {
        var snapshot = SystemSnapshot.sample()
        snapshot.memory?.topProcesses = [MemoryProcessInfo(name: "secret-client-worker", bytes: 1)]
        let text = SnapshotRenderer.render(snapshot) { $0.replacingOccurrences(of: "secret-client", with: "<папка-1>") }
        XCTAssertFalse(text.contains("secret-client"))
        XCTAssertTrue(text.contains("<папка-1>-worker"))
    }

    func testItemCardShowsTheArticle() {
        let card = SnapshotRenderer.itemCard(SystemSnapshot.sample().items[0], articleID: "path.xcode-deriveddata") { $0 }
        XCTAssertTrue(card.hasSuffix("Справка: path.xcode-deriveddata"))
        XCTAssertFalse(SnapshotRenderer.itemCard(SystemSnapshot.sample().items[0]) { $0 }.contains("Справка:"))
    }
```

`MemoryInfo.topProcesses` is a `var`, but `SystemSnapshot.memory` is optional, so `snapshot.memory?.topProcesses = ...` compiles.

- [ ] **Step 2: Register and run to see them fail**

```bash
scripts/xcodeproj-add.py tests SpotlessMacTests SpotlessMacTests/KnowledgeRendererTests.swift
scripts/test.sh KnowledgeRendererTests SnapshotRendererTests
```

Expected: build errors (`cannot find 'KnowledgeRenderer'`, `extra argument 'knowledge'`).

- [ ] **Step 3: Implement `KnowledgeRenderer`**

`SpotlessMac/Assistant/KnowledgeRenderer.swift`:

```swift
import Foundation

// Turns articles into the text the model reads: full articles, lookup results, the
// «Справка по найденному» section and the tools-off reference. All limits are in characters.
enum KnowledgeRenderer {
    static let articleLimit = 3_000
    static let lookupLimit = 6_000
    static let sectionLimit = 2_500
    static let sectionEntries = 12
    static let injectedLimit = 4_000

    static func article(_ article: KnowledgeArticle, limit: Int = articleLimit) -> String {
        var lines = [
            "[\(article.id)] \(article.title)",
            "Вердикт: \(article.verdict.label)",
            "Кратко: \(article.summary)",
            article.body,
        ]
        if !article.related.isEmpty { lines.append("См. также: " + article.related.joined(separator: ", ")) }
        return truncated(lines.joined(separator: "\n"), to: limit)
    }

    // `id` wins when it exists. An unknown id falls back to `query`, or, without a query, to similar titles.
    static func lookup(id: String?, query: String?, in base: KnowledgeBase) -> String {
        if let id, let found = base.article(id: id) { return article(found) }
        let prefix = id.map { "Статья \($0) не найдена. " } ?? ""
        let text = query ?? id.map { $0.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ") } ?? ""
        let hits = base.search(text, limit: 3)
        guard !hits.isEmpty else {
            return prefix + "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет."
        }
        if query == nil {
            return prefix + "Похожие статьи: "
                + hits.map { "\($0.article.id) — \($0.article.title)" }.joined(separator: "; ") + "."
        }
        return prefix + joined(hits.map(\.article), header: "Найдено в справке: \(hits.count).", limit: lookupLimit)
    }

    // Tools-off mode: the best articles for the user's question, sent as one more system message.
    static func injected(for question: String, in base: KnowledgeBase) -> String? {
        let hits = base.search(question, limit: 2)
        guard !hits.isEmpty else { return nil }
        return joined(hits.map(\.article), header: "Справка SpotlessMac по вопросу:", limit: injectedLimit)
    }

    // Each matched article once, the one covering the most bytes first.
    static func section(_ snapshot: SystemSnapshot, context: KnowledgeContext) -> String? {
        var weight: [String: Int64] = [:]
        for item in snapshot.items {
            if let id = context.annotations.items[item.shortID] { weight[id, default: 0] += item.bytes }
        }
        for app in snapshot.memory?.topApps ?? [] {
            if let id = context.annotations.apps[app.name] { weight[id, default: 0] += app.bytes }
        }
        for process in snapshot.memory?.topProcesses ?? [] {
            if let id = context.annotations.processes[process.name] { weight[id, default: 0] += process.bytes }
        }
        let ordered = weight
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { context.base.article(id: $0.key) }
        var lines = ["Справка SpotlessMac по найденному (id — вердикт — кратко):"]
        var used = lines[0].count
        for article in ordered.prefix(sectionEntries) {
            let line = "- \(article.id) — \(article.verdict.label) — \(article.summary)"
            guard used + 1 + line.count <= sectionLimit else { break }
            lines.append(line)
            used += 1 + line.count
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    private static func joined(_ articles: [KnowledgeArticle], header: String, limit: Int) -> String {
        var text = header
        for item in articles {
            let block = "\n\n" + article(item)
            guard text.count + block.count <= limit else { break }
            text += block
        }
        return text
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
```

- [ ] **Step 4: Update `SnapshotRenderer`**

1. Add `static let itemColumns = "ID | путь | размер | категория | политика | изменён | владелец | справка"`.
2. Change the signature to `static func render(_ snapshot: SystemSnapshot, knowledge: KnowledgeContext = .none, formatPath: (String) -> String) -> String`.
3. Items header becomes `lines.append("Крупные элементы (\(itemColumns)):")` and the per-item line becomes `itemLine(item, articleID: knowledge.annotations.items[item.shortID], formatPath: formatPath)`.
4. Replace the memory block with:

```swift
        if let memory = snapshot.memory {
            var line = "Память: давление \(memory.load.label), занято \(memoryBytes(memory.usedBytes)) из \(memoryBytes(memory.physicalBytes)), своп \(memoryBytes(memory.swapUsedBytes))."
            if !memory.topApps.isEmpty {
                line += " Больше всего памяти занимают: "
                    + memory.topApps.map { app in
                        "\(app.name) — \(memoryBytes(app.bytes))" + tag(knowledge.annotations.apps[app.name])
                    }.joined(separator: ", ") + "."
            }
            lines.append(line)
            if !memory.topProcesses.isEmpty {
                // Names of non-system processes can be user scripts, so they go through formatPath.
                lines.append("Крупные процессы вне программ: " + memory.topProcesses.map { process in
                    "\(formatPath(process.name)) — \(memoryBytes(process.bytes))" + tag(knowledge.annotations.processes[process.name])
                }.joined(separator: ", ") + ".")
            }
        } else {
            lines.append("Память: данные не получены.")
        }
        if let section = KnowledgeRenderer.section(snapshot, context: knowledge) {
            lines.append(section)
        }
```

and add `private static func tag(_ id: String?) -> String { id.map { " [\($0)]" } ?? "" }`.
5. `itemLine` gains `articleID: String? = nil` (before `formatPath`) and appends `articleID ?? "—"` as the last column.
6. `itemCard` gains `articleID: String? = nil` (before `formatPath`); after building the array, append `"Справка: \(articleID)"` when non-nil.

- [ ] **Step 5: Run the affected suites and fix exact-string expectations**

Run: `scripts/test.sh KnowledgeRendererTests SnapshotRendererTests AssistantToolboxTests AssistantViewModelTests`
Expected: PASS. If an existing assertion compared a full item line or card exactly, append ` | —` to the expected line (that is the intended new column), never remove the column.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/Assistant/KnowledgeRenderer.swift SpotlessMac/Assistant/SnapshotRenderer.swift \
  SpotlessMacTests/KnowledgeRendererTests.swift SpotlessMacTests/SnapshotRendererTests.swift SpotlessMac.xcodeproj/project.pbxproj
git commit -m "feat(knowledge): render article references into the assistant context

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `lookup_knowledge` tool

**Files:**
- Modify: `SpotlessMac/Assistant/AssistantTool.swift`
- Modify: `SpotlessMac/Assistant/AssistantToolbox.swift`
- Test: `SpotlessMacTests/AssistantToolboxTests.swift`, `SpotlessMacTests/AssistantIsolationTests.swift` (`testToolSetIsClosedAndReadOnly` expected names)

**Interfaces:**
- Consumes: `KnowledgeContext` (Task 6), `KnowledgeRenderer.lookup`, `SnapshotRenderer.itemLine/itemCard(articleID:)`, `SnapshotRenderer.itemColumns` (Task 7).
- Produces:
  - `AssistantTool.lookupKnowledge(id: String?, query: String?)`; `AssistantTool.names == ["list_items", "item_details", "propose_plan", "lookup_knowledge"]`
  - `AssistantToolbox.execute(_ call: ToolCall, snapshot: SystemSnapshot, knowledge: KnowledgeContext = .none, formatPath: (String) -> String) -> ToolOutcome`

- [ ] **Step 1: Write the failing tests** (append to `AssistantToolboxTests`)

```swift
    private func knowledge() -> KnowledgeContext {
        let base = KnowledgeFixtures.base([
            KnowledgeFixtures.article("guide.swap", title: "Своп и подкачка", summary: "Файл подкачки."),
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, title: "DerivedData", verdict: .safe),
        ])
        return KnowledgeContext(base: base, annotations: KnowledgeAnnotations(items: ["c1": "path.xcode-deriveddata"]))
    }

    private func lookup(_ arguments: String) -> String {
        AssistantToolbox.execute(ToolCall(id: "k", name: "lookup_knowledge", argumentsJSON: arguments),
                                 snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
    }

    func testLookupKnowledgeByID() {
        XCTAssertTrue(lookup(#"{"id":"guide.swap"}"#).hasPrefix("[guide.swap] Своп и подкачка"))
    }

    func testLookupKnowledgeByQuery() {
        XCTAssertTrue(lookup(#"{"query":"что такое своп"}"#).contains("[guide.swap]"))
    }

    func testLookupKnowledgeRejectsBadArguments() {
        XCTAssertEqual(lookup("{}"), "Ошибка в аргументах lookup_knowledge: нужен id или query.")
        XCTAssertEqual(lookup(#"{"id":"  ","query":null}"#), "Ошибка в аргументах lookup_knowledge: нужен id или query.")
        XCTAssertEqual(lookup(#"{"id":5}"#), "Ошибка в аргументах lookup_knowledge: id должно быть строкой.")
        XCTAssertEqual(lookup(#"{"query":true}"#), "Ошибка в аргументах lookup_knowledge: query должно быть строкой.")
        XCTAssertEqual(lookup("[]"), "Ошибка в аргументах lookup_knowledge: аргументы должны быть JSON-объектом.")
    }

    func testLookupKnowledgeUnknownIDAndNoHits() {
        XCTAssertTrue(lookup(#"{"id":"guide.nope"}"#).hasPrefix("Статья guide.nope не найдена."))
        XCTAssertEqual(lookup(#"{"query":"zzzz"}"#),
                       "В справке ничего не найдено. Отвечай осторожно и скажи, что точных данных нет.")
    }

    func testLookupKnowledgeNeverProposesAPlan() {
        let outcome = AssistantToolbox.execute(ToolCall(id: "k", name: "lookup_knowledge", argumentsJSON: #"{"query":"своп"}"#),
                                               snapshot: .sample(), knowledge: knowledge()) { $0 }
        XCTAssertNil(outcome.proposal)
    }

    func testListItemsAndDetailsShowTheArticle() {
        let list = AssistantToolbox.execute(ToolCall(id: "l", name: "list_items", argumentsJSON: #"{"category":"developer_caches"}"#),
                                            snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
        XCTAssertTrue(list.contains("Колонки: \(SnapshotRenderer.itemColumns):"))
        XCTAssertTrue(list.contains("| path.xcode-deriveddata"))
        let card = AssistantToolbox.execute(ToolCall(id: "d", name: "item_details", argumentsJSON: #"{"id":"c1"}"#),
                                            snapshot: .sample(), knowledge: knowledge()) { $0 }.resultText
        XCTAssertTrue(card.contains("Справка: path.xcode-deriveddata"))
    }

    func testUnknownToolListsAllFourTools() {
        let text = AssistantToolbox.execute(ToolCall(id: "x", name: "rm", argumentsJSON: "{}"), snapshot: .sample()) { $0 }.resultText
        XCTAssertTrue(text.contains("list_items, item_details, propose_plan и lookup_knowledge"))
    }
```

In `AssistantIsolationTests.testToolSetIsClosedAndReadOnly`, change the expected names to
`["list_items", "item_details", "propose_plan", "lookup_knowledge"]` (the closed-set and junk-name checks stay unchanged).

- [ ] **Step 2: Run to see them fail**

Run: `scripts/test.sh AssistantToolboxTests AssistantIsolationTests`
Expected: build error `extra argument 'knowledge' in call`.

- [ ] **Step 3: Implement in `AssistantTool.swift`**

1. Add the case `case lookupKnowledge(id: String?, query: String?)`.
2. `static let names = ["list_items", "item_details", "propose_plan", "lookup_knowledge"]`.
3. In `specs`, before `return [...]`:

```swift
        let lookupKnowledge: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "ID статьи справки, например proc.kernel-task или из колонки «справка»"],
                "query": ["type": "string", "description": "Вопрос или ключевые слова по-русски: процесс, папка, программа, проблема"],
            ],
        ]
```

and append to the returned array:

```swift
            ToolSpec(name: "lookup_knowledge", description: "Найти статью во встроенной справке SpotlessMac о процессах, папках, памяти, настройках macOS и организации файлов. Ничего не меняет.", parametersJSON: JSONText.string(from: lookupKnowledge)),
```

4. In `parse`, before `default:`:

```swift
        case "lookup_knowledge":
            do throws(ToolParseError) {
                return .success(try parseLookup(arguments))
            } catch {
                return .failure(error)
            }
```

5. Add next to `parseListItems`:

```swift
    // Both fields are optional strings, but at least one must carry text; blank strings count as absent.
    private static func parseLookup(_ arguments: [String: Any]) throws(ToolParseError) -> AssistantTool {
        func text(_ key: String) throws(ToolParseError) -> String? {
            guard let value = provided(arguments[key]) else { return nil }
            guard let string = value as? String else { throw .invalidArguments("\(key) должно быть строкой") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let id = try text("id")
        let query = try text("query")
        guard id != nil || query != nil else { throw .invalidArguments("нужен id или query") }
        return .lookupKnowledge(id: id, query: query)
    }
```

- [ ] **Step 4: Implement in `AssistantToolbox.swift`**

1. Signature: `static func execute(_ call: ToolCall, snapshot: SystemSnapshot, knowledge: KnowledgeContext = .none, formatPath: (String) -> String) -> ToolOutcome`.
2. Unknown tool text: `"Ошибка: инструмента «\(name)» не существует. Доступны только list_items, item_details, propose_plan и lookup_knowledge. Удалять файлы, запускать команды и менять систему ассистент не может."`
3. `list_items` header: `"Найдено \(matches.count), показано \(shown.count)\(filters). Колонки: \(SnapshotRenderer.itemColumns):"`; lines: `SnapshotRenderer.itemLine($0, articleID: knowledge.annotations.items[$0.shortID], formatPath: formatPath)`.
4. `item_details`: `SnapshotRenderer.itemCard(item, articleID: knowledge.annotations.items[item.shortID], formatPath: formatPath)`.
5. New case:

```swift
        case .success(.lookupKnowledge(let id, let query)):
            return ToolOutcome(resultText: KnowledgeRenderer.lookup(id: id, query: query, in: knowledge.base), proposal: nil)
```

- [ ] **Step 5: Run**

Run: `scripts/test.sh AssistantToolboxTests AssistantIsolationTests AssistantViewModelTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add SpotlessMac/Assistant/AssistantTool.swift SpotlessMac/Assistant/AssistantToolbox.swift \
  SpotlessMacTests/AssistantToolboxTests.swift SpotlessMacTests/AssistantIsolationTests.swift
git commit -m "feat(assistant): read-only lookup_knowledge tool

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Wire the base into the assistant (dependencies, prompt, tools-off injection)

**Files:**
- Modify: `SpotlessMac/Assistant/AssistantViewModel.swift` (`Dependencies`, `respond`, `systemMessages`, `status(for:)`)
- Modify: `SpotlessMac/Assistant/AssistantPrompt.swift` (`base`, `guardrails`, `toolsGuide`)
- Modify: `SpotlessMac/Assistant/AssistantGuard.swift` (`refusal` wording only)
- Modify: `SpotlessMac/App/ContentView.swift:128-151` (`makeAssistant`)
- Test: `SpotlessMacTests/AssistantViewModelTests.swift`, `SpotlessMacTests/AssistantIsolationTests.swift`, `SpotlessMacTests/SnapshotRendererTests.swift` (`testPromptVariants`)

**Interfaces:**
- Consumes: `KnowledgeBase.loadBundled(from:)` (Task 3), `KnowledgeMatcher.annotate`, `KnowledgeContext` (Task 6), `KnowledgeRenderer.injected` (Task 7), `AssistantToolbox.execute(... knowledge:)` (Task 8); guard API from the Prerequisite (`AssistantGuard.Tokens`, `AssistantGuard.fence`, `AssistantPrompt.guardrails(tokens:)`).
- Produces: `AssistantViewModel.Dependencies.knowledge: KnowledgeBase` (default `.empty`), declared right after `personalRoots`.

- [ ] **Step 1: Write the failing tests**

In `AssistantViewModelTests.makeViewModel`, add a parameter `knowledge: KnowledgeBase = .empty` and pass `knowledge: knowledge,` right after `personalRoots: personalRoots,`. Then append:

```swift
    private func knowledgeBase() -> KnowledgeBase {
        KnowledgeFixtures.base([
            KnowledgeFixtures.article("guide.swap", title: "Своп и подкачка", summary: "Файл подкачки."),
            KnowledgeFixtures.article("path.xcode-deriveddata", kind: .path, summary: "Сборки Xcode.", verdict: .safe,
                                      paths: ["~/Library/Developer/Xcode/DerivedData"]),
        ])
    }

    func testContextCarriesKnowledgeSection() async {
        let client = FakeLLMClient([.events([.text("Ок"), .done])])
        let vm = makeViewModel(client, knowledge: knowledgeBase())
        await sendAndWait(vm, "Что занимает место?")
        let context = client.requests[0].messages[1].content
        XCTAssertTrue(context.contains("| path.xcode-deriveddata"))
        XCTAssertTrue(context.contains("- path.xcode-deriveddata — безопасно — Сборки Xcode."))
    }

    func testLookupToolReadsTheBase() async {
        let call = ToolCall(id: "k1", name: "lookup_knowledge", argumentsJSON: #"{"query":"своп"}"#)
        let client = FakeLLMClient([.events([.toolCalls([call]), .done]), .events([.text("Своп — это…"), .done])])
        let vm = makeViewModel(client, knowledge: knowledgeBase())
        await sendAndWait(vm, "Что такое своп?")
        XCTAssertTrue(client.requests[1].messages.last?.content.contains("[guide.swap]") ?? false)
    }

    func testToolsOffInjectsReference() async {
        let client = FakeLLMClient([.events([.text("Ок"), .done])])
        let vm = makeViewModel(client, toolMode: .off, knowledge: knowledgeBase())
        await sendAndWait(vm, "Что такое своп?")
        let systems = client.requests[0].messages.filter { $0.role == .system }
        XCTAssertEqual(systems.count, 3)
        XCTAssertTrue(systems[2].content.hasPrefix("Справка SpotlessMac по вопросу:"))
        XCTAssertTrue(systems[2].content.contains("[guide.swap]"))
    }

    func testToolsOnDoesNotInject() async {
        let client = FakeLLMClient([.events([.text("Ок"), .done])])
        let vm = makeViewModel(client, toolMode: .on, knowledge: knowledgeBase())
        await sendAndWait(vm, "Что такое своп?")
        XCTAssertEqual(client.requests[0].messages.filter { $0.role == .system }.count, 2)
    }

    func testFallbackRequestInjectsReferenceAfterToolsUnsupported() async {
        let client = FakeLLMClient([.failure(LLMError.toolsUnsupported), .events([.text("Ок"), .done])])
        let vm = makeViewModel(client, toolMode: .auto, knowledge: knowledgeBase())
        await sendAndWait(vm, "Что такое своп?")
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[1].tools.isEmpty)
        XCTAssertTrue(client.requests[1].messages.contains { $0.role == .system && $0.content.hasPrefix("Справка SpotlessMac по вопросу:") })
    }

    func testCloudRequestWithKnowledgeStaysRedacted() async {
        let client = FakeLLMClient([.events([.text("Ок"), .done])])
        let vm = makeViewModel(client, provider: .ollamaCloud, knowledge: knowledgeBase())
        vm.acceptCloudDisclosure()
        await sendAndWait(vm, "Что занимает место?")
        let everything = client.requests[0].messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(everything.contains("/Users/tester"))
        XCTAssertFalse(everything.contains("secret-client"))
        XCTAssertTrue(everything.contains("path.xcode-deriveddata"))
    }
```

In `AssistantIsolationTests.testViewModelDependenciesExposeOnlyTheApprovedCapabilities`, add `"knowledge"` to the expected label set and change the count to `11`.

In `SnapshotRendererTests.testPromptVariants` (the guard work may have added a `tokens:` argument to these calls — keep it), add:

```swift
        XCTAssertTrue(tools.contains("lookup_knowledge"))
        XCTAssertTrue(fallback.contains("Справка SpotlessMac"))
        XCTAssertTrue(fallback.contains("Политика элемента в снимке"))
        XCTAssertTrue(fallback.contains("организации файлов"))
```

- [ ] **Step 2: Run to see them fail**

Run: `scripts/test.sh AssistantViewModelTests AssistantIsolationTests SnapshotRendererTests`
Expected: build error `extra argument 'knowledge' in call`.

Also add to `AssistantViewModelTests` (guard regression for knowledge text):

```swift
    func testFileOrganizationQuestionIsNotRefusedLocally() {
        XCTAssertFalse(AssistantGuard.isInjectionAttempt("Как навести порядок в папке Загрузки?"))
        XCTAssertFalse(AssistantGuard.isInjectionAttempt("Что за процесс kernel_task?"))
    }
```

- [ ] **Step 3: Implement the view model changes**

1. In `Dependencies`, after `personalRoots`:

```swift
        // Bundled read-only articles about macOS; the assistant only ever reads them.
        var knowledge: KnowledgeBase = .empty
```

2. In `respond(into:settings:)`, right after `let snapshot = Self.prepared(deps.snapshot(), redacts: redacts)`:

```swift
        // Matching runs on real paths; only article ids and article text reach the model.
        let knowledge = KnowledgeContext(
            base: deps.knowledge,
            annotations: KnowledgeMatcher.annotate(snapshot, knowledge: deps.knowledge, homePath: deps.homePath))
        let question = messages.last(where: { $0.role == .user })?.text ?? ""
```

3. Render, keeping the guard's fence: `let context = AssistantGuard.fence(SnapshotRenderer.render(snapshot, knowledge: knowledge) { self.format($0, redacts: redacts) }, tokens: tokens)`.
4. Request messages: `messages: systemMessages(toolsEnabled: toolsEnabled, context: context, tokens: tokens, question: question) + conversation`.
5. Tool execution: `AssistantToolbox.execute(call, snapshot: snapshot, knowledge: knowledge) { self.format($0, redacts: redacts) }` — its result keeps going through `AssistantGuard.fence` when appended to `conversation`.
6. Replace `systemMessages`:

```swift
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
```

7. In `status(for:)` add `case "lookup_knowledge": "Читаю справку…"` before `default`.

- [ ] **Step 4: Update the prompt**

In `AssistantPrompt.base`, replace the line
`- Опирайся только на снимок системы и результаты инструментов. Если элемента нет в данных — скажи «не знаю», не придумывай пути и размеры.`
with:

```
    - Опирайся на снимок системы, результаты инструментов и справку SpotlessMac. Если элемента нет в данных — скажи «не знаю», не придумывай пути и размеры.
    - Справка SpotlessMac — проверенные статьи о процессах, папках, памяти, настройках macOS и организации файлов. Отвечая на такие вопросы, сначала проверь справку: раздел «Справка по найденному», статьи по вопросу или инструмент lookup_knowledge. Если справка расходится с твоими знаниями — следуй справке; можешь назвать статью, на которую опираешься.
    - Политика элемента в снимке (personalData, inspectOnly) главнее справки.
    - Не придумывай пункты Системных настроек, которых нет в справке. Если справки по теме нет — так и скажи и отвечай осторожно.
```

In `AssistantPrompt.guardrails(tokens:)`, widen the first scope rule so knowledge-base topics are not refused. Replace
`- Отвечай только на вопросы о месте на диске, очистке, кешах, памяти и обслуживании этого Mac и о том, как пользоваться SpotlessMac.`
with
`- Отвечай только на вопросы о месте на диске, очистке, кешах, памяти, процессах и быстродействии, организации файлов и обслуживании этого Mac и о том, как пользоваться SpotlessMac.`
(keep the rest of that line — the refusal for everything else — unchanged). Also update `AssistantGuard.refusal` to mention files: «Я помогаю только с местом на диске, очисткой, памятью и порядком в файлах этого Mac — …». Check `AssistantGuardTests` for assertions on the exact old wording and update them to the new wording.

Replace `toolsGuide` with:

```swift
    static let toolsGuide = """
    Инструменты: list_items — найти элементы по категории, размеру и возрасту; item_details — подробности по ID; propose_plan — предложить план очистки (ID элементов и/или фильтры по категории); lookup_knowledge — статья справки по id (например, из колонки «справка») или поиск по вопросу. Инструментов удаления нет. Вызывай propose_plan не больше одного раза за ответ и после него кратко объясни план словами.
    """
```

- [ ] **Step 5: Wire the app**

In `ContentView`, add next to `registeredProjectRoots`:

```swift
    // Parsed once per launch; the assistant gets it as an immutable value.
    private static let knowledgeBase = KnowledgeBase.loadBundled(from: .main)
```

and in `makeAssistant()` pass `knowledge: Self.knowledgeBase,` right after `personalRoots: ...,`.

- [ ] **Step 6: Run the full suite and build**

```bash
scripts/test.sh
xcodebuild -project SpotlessMac.xcodeproj -scheme SpotlessMac -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO | tail -2
```

Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add SpotlessMac/Assistant/AssistantViewModel.swift SpotlessMac/Assistant/AssistantPrompt.swift SpotlessMac/Assistant/AssistantGuard.swift \
  SpotlessMac/App/ContentView.swift SpotlessMacTests/AssistantViewModelTests.swift SpotlessMacTests/AssistantIsolationTests.swift \
  SpotlessMacTests/SnapshotRendererTests.swift SpotlessMacTests/AssistantGuardTests.swift
git commit -m "feat(assistant): use the bundled knowledge base in answers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Content tasks (10, 11, 12): shared rules

Every content task writes articles into `SpotlessMac/Resources/Knowledge/` and one eval file. Rules (all enforced by `KnowledgeCorpusTests`/`KnowledgeEvalTests` except where noted):

1. **Format** — exactly as the seed articles from Task 3 (copy one as a template). Front matter keys in this order: `id, kind, title, summary, verdict, aliases, keywords, processes | bundles | paths, categories, related, macOS, reviewed, sources`. `reviewed: 2026-10-03`. `macOS: 14-26` unless a fact is version-specific (then narrow it and say so in the body).
2. **Bindings** — use exactly the binding keys given in the task table; do not invent more. `process` articles carry only `processes`; `app` only `bundles` (+ `aliases` with the app's display name); `path` only `paths`/`categories`; guides none and `verdict: info`.
3. **Facts** — verify every factual claim with WebSearch/WebFetch against Apple Support, Apple Developer documentation, man pages or the vendor's own documentation, and put those URLs in `sources` (`https://…` or `man:<page>`). Write in your own words; never copy text from third-party sites. If a fact cannot be verified, leave it out.
4. **Settings paths** — name System Settings panes as they appear in macOS 14–26 («Системные настройки → Основные → Объекты входа»). If the name differs between versions, give both. Mark every UI path you could not confirm with a public Apple page in the commit message under «Unverified UI paths:» so the human reviewer checks it on a Mac.
5. **Safety** — no terminal commands or code at all (the assistant never suggests commands; the guard would hide them); never the words in `KnowledgeCorpusTests.forbiddenWords`; describe GUI steps instead (Finder, System Settings, Disk Utility, the app's own settings). Point to SpotlessMac features by their UI names (tabs «Чистка», «Программы», «Диск» with «Освободить место», «Память», «Docker»). Never promise that the assistant will do anything itself.
6. **Size** — `summary` ≤ 160 characters, body 400–2,500 characters; sections `## Что это` and `## Что делать` mandatory, others in the canonical order.
7. **Eval** — add 1–2 realistic Russian user questions per article (how a non-expert would type them, including colloquial words) to the task's eval file. Tune `aliases`/`keywords` until `KnowledgeEvalTests` passes; do not change `KnowledgeSearch`.
8. **Related** — only ids from `KnowledgeCorpusTests.wave1`.
9. Verify with `scripts/test.sh KnowledgeCorpusTests KnowledgeEvalTests KnowledgeMatcherTests`, then commit only `SpotlessMac/Resources/Knowledge/*.md` and the task's eval file.

### Task 10: Content — processes and apps (14 articles)

**Files:**
- Create: `SpotlessMac/Resources/Knowledge/<id>.md` for each row below
- Create: `SpotlessMacTests/Fixtures/knowledge-eval-processes.json`

**Interfaces:**
- Consumes: article format, corpus lint, eval harness (Tasks 3–4).
- Produces: the 14 articles below (with the seed `proc.spotlight-indexing` this completes the 15 wave-1 process/app articles).

| id | verdict | Bindings | Must cover |
|---|---|---|---|
| `proc.kernel-task` | keep | `processes: [kernel_task]` | Kernel; high CPU is often thermal management (it occupies the CPU to cool the Mac); causes: heat, charging on the right side on older Intel laptops, external displays; what to do: ventilation, close heavy apps |
| `proc.windowserver` | keep | `processes: [WindowServer]` | Draws everything on screen; grows with external/high-res displays, many windows, transparency/animation; what to do: fewer windows, Reduce transparency (Accessibility → Display) |
| `proc.photos-analysis` | keep | `processes: [photoanalysisd, mediaanalysisd, photolibraryd]` | Faces/objects/memories analysis in Photos; runs when idle and on power; after import/update; let it finish |
| `proc.icloud-sync` | keep | `processes: [bird, cloudd, fileproviderd]` | iCloud Drive/Desktop & Documents sync; heavy after enabling or big changes; check iCloud status in Finder sidebar; don't delete local copies by hand |
| `proc.backupd` | keep | `processes: [backupd, backupd-helper]` | Time Machine backup in progress; first backup is long; pause via Time Machine settings, not by force-quitting |
| `proc.software-update` | keep | `processes: [softwareupdated, nsurlsessiond]` | Downloading/preparing macOS updates and background downloads; network/disk load; where to see updates (Системные настройки → Основные → Обновление ПО) |
| `proc.webkit` | caution | `processes: [com.apple.WebKit.WebContent, com.apple.WebKit.Networking, com.apple.WebKit.GPU]` | Safari and apps using WebKit; one content process per tab/site; heavy pages; close tabs; unsaved form data risk |
| `proc.virtualization` | caution | `processes: [com.apple.Virtualization.VirtualMachine]` | VM of Docker Desktop, UTM, Parallels-like apps on Apple's framework; reserves the RAM given to the VM; lower the VM memory limit in the app's settings; stop VMs you don't use |
| `proc.dev-runtimes` | caution | `processes: [node, python, python3, java, ruby, deno, bun]` | Dev servers, scripts, language servers left running; how to find what started them (terminal windows, editors); stopping them may lose unsaved work |
| `app.chrome` | safe | `bundles: [com.google.Chrome]`, `aliases: [Google Chrome, Chrome, хром]` | Process-per-tab model; extensions; Memory Saver setting (Настройки Chrome → Производительность); built-in Task Manager (Shift+Esc on Windows; on Mac: Окно → Диспетчер задач); SpotlessMac «Память» shows tabs vs extensions |
| `app.electron` | safe | `bundles: [com.tinyspeck.slackmacgap, com.hnc.Discord, com.microsoft.teams2, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92]`, `aliases: [Slack, Discord, Microsoft Teams, Visual Studio Code, Cursor]` | Each is a bundled Chromium; why heavy; quit instead of keeping in background; caches regrow (link `path.user-caches`) — verify the Cursor bundle ID on a Mac or in vendor docs before committing; drop it if unverifiable |
| `app.docker` | caution | `bundles: [com.docker.docker]`, `aliases: [Docker, Docker Desktop]` | RAM reserved by the VM (Settings → Resources); stopping Docker frees it; disk in `path.docker-raw`; SpotlessMac «Docker» tab |
| `app.telegram` | safe | `bundles: [ru.keepcoder.Telegram, org.telegram.desktop]`, `aliases: [Telegram, телеграм]` | Media cache; storage limit and auto-clear in Telegram settings (Данные и память → Использование памяти); cloud chats re-download |
| `app.xcode` | caution | `bundles: [com.apple.dt.Xcode]`, `aliases: [Xcode]` | Memory use of indexing/build/simulators; disk: DerivedData, DeviceSupport, simulators (link path articles); Settings → Platforms to remove simulator runtimes |

- [ ] **Step 1:** For each row, research and write the article following the shared rules.
- [ ] **Step 2:** Write `knowledge-eval-processes.json` with 1–2 queries per article (≥ 20 total), e.g. `{"query": "kernel_task грузит процессор на 300%", "expected": "proc.kernel-task"}`.
- [ ] **Step 3:** Run `scripts/test.sh KnowledgeCorpusTests KnowledgeEvalTests KnowledgeMatcherTests`. Expected: PASS and `Knowledge eval: N/N` with ≥ 90%.
- [ ] **Step 4:** Commit:

```bash
git add SpotlessMac/Resources/Knowledge SpotlessMacTests/Fixtures/knowledge-eval-processes.json
git commit -m "content(knowledge): processes and apps, wave 1

Unverified UI paths: <list or 'none'>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 11: Content — paths (15 articles)

**Files:**
- Create: `SpotlessMac/Resources/Knowledge/<id>.md` for each row below
- Create: `SpotlessMacTests/Fixtures/knowledge-eval-paths.json`

**Interfaces:**
- Consumes: as Task 10.
- Produces: 15 path articles (with the seed `path.xcode-deriveddata`, all 16 wave-1 path articles). Every `ScanCategory` used here as a fallback must be bound exactly once across the corpus.

| id | verdict | Bindings | Must cover |
|---|---|---|---|
| `path.user-caches` | safe | `paths: [~/Library/Caches]`, `categories: [user_caches, known_app_caches]` | App caches; regenerate; close the app first; first launch slower |
| `path.logs` | safe | `paths: [~/Library/Logs]`, `categories: [logs]` | Diagnostic logs and crash reports; not needed for normal work; keep a crash report if you are about to send it to a developer |
| `path.xcode-device-support` | safe | `paths: [~/Library/Developer/Xcode/iOS DeviceSupport, ~/Library/Developer/Xcode/watchOS DeviceSupport]` | Symbols per connected device OS version; regenerated on next connect; old versions safe to remove |
| `path.coresimulator` | caution | `paths: [~/Library/Developer/CoreSimulator]` | Simulator devices with app data; delete unused devices in Xcode (Window → Devices and Simulators) or runtimes in Xcode Settings → Platforms; data inside simulators is lost |
| `path.iphone-backups` | keep | `paths: [~/Library/Application Support/MobileSync/Backup]` | Local iPhone/iPad backups; may be the only copy; manage in Finder (device → Manage Backups); never delete by hand without checking |
| `path.mobile-documents` | keep | `paths: [~/Library/Mobile Documents]` | iCloud Drive local store; deleting here deletes from iCloud on all devices; use «Optimize Mac Storage» instead (link `guide.optimize-storage`) |
| `path.photos-library` | keep | `paths: [~/Pictures/*.photoslibrary]` | Photos library package; never edit inside; reduce via Photos settings (iCloud Photos → Optimize Mac Storage) or by deleting in Photos (Recently Deleted) |
| `path.messages-attachments` | keep | `paths: [~/Library/Messages]` | Messages history and attachments; use Messages settings (keep messages 30 days / 1 year) or Storage settings to review large attachments |
| `path.docker-raw` | caution | `paths: [~/Library/Containers/com.docker.docker/Data/vms]` | Docker disk image; does not shrink by itself; clean images/volumes in SpotlessMac «Docker» tab or Docker Desktop; deleting the file wipes all containers, images and volumes |
| `path.package-caches` | safe | `paths: [~/Library/Caches/Homebrew, ~/.npm, ~/Library/pnpm, ~/.pnpm-store, ~/Library/Caches/Yarn, ~/Library/Caches/pip, ~/.cache/pip, ~/.cache/uv]`, `categories: [developer_caches]` | Downloaded packages kept for reuse; re-downloaded on demand; offline installs may fail after cleanup |
| `path.ml-models` | caution | `paths: [~/.cache/huggingface, ~/.ollama/models, ~/.lmstudio/models]`, `categories: [model_caches]` | Model weights, often tens of GB each; re-download cost/time; remove models you no longer use from the tool itself when possible |
| `path.project-artifacts` | caution | `categories: [project_artifacts]` | node_modules, target, build, .venv in projects; reinstall/rebuild needed; check the project isn't open/running |
| `path.old-installers` | safe | `categories: [old_installers]` | .dmg/.pkg in Downloads; not needed after install; keep if it's a version you can't download again |
| `path.trash` | caution | `paths: [~/.Trash]`, `categories: [trash]` | Items already deleted; emptying is irreversible; Finder setting to empty after 30 days |
| `path.swap` | keep | `paths: [/private/var/vm]` | Swap files and sleep image; managed by macOS; shrink only by closing apps/restarting (link `guide.high-swap`) |

- [ ] **Step 1:** Write the articles following the shared rules.
- [ ] **Step 2:** Write `knowledge-eval-paths.json` (≥ 20 queries), e.g. `{"query": "можно ли удалить резервные копии айфона", "expected": "path.iphone-backups"}`.
- [ ] **Step 3:** Run `scripts/test.sh KnowledgeCorpusTests KnowledgeEvalTests KnowledgeMatcherTests`. Expected: PASS, including `testSafeArticlesNeverCoverProtectedRoots` and `testBindingKeysAreUnique`.
- [ ] **Step 4:** Commit (`content(knowledge): paths, wave 1`, same trailer format as Task 10).

### Task 12: Content — guides (17 articles)

**Files:**
- Create: `SpotlessMac/Resources/Knowledge/<id>.md` for each row below
- Create: `SpotlessMacTests/Fixtures/knowledge-eval-guides.json`

**Interfaces:**
- Consumes: as Task 10.
- Produces: 17 guides (with the seed `guide.memory-pressure`, all 18 wave-1 guides). `guide.large-media` carries `categories: [large_files]`; `guide.file-organization` carries `categories: [recordings]`. Note: guides may hold `categories` (the lint allows it) but no other bindings.

| id | Must cover |
|---|---|
| `guide.system-data` | What «Системные данные» includes (caches, logs, local snapshots, VM/swap, app support data); why it fluctuates; what SpotlessMac can and can't reduce |
| `guide.space-not-freed` | Trash not emptied; purgeable space; local Time Machine snapshots (seen in Disk Utility with APFS snapshots shown — verify the menu name); APFS reporting delay |
| `guide.high-swap` | When swap is a problem (with yellow/red pressure), what to close, when a restart helps |
| `guide.no-ram-cleaners` | Why "RAM cleaner" apps and forced memory freeing don't help; file cache is useful |
| `guide.slow-after-update` | Spotlight/Photos analysis/iCloud re-sync after updates; wait on power for a day; check «Память» |
| `guide.browser-memory` | Tabs, extensions, Safari/Chrome memory-saving modes, tab groups, closing pinned heavy web apps |
| `guide.login-items` | Системные настройки → Основные → Объекты входа (and «Разрешить в фоновом режиме»); what's safe to turn off |
| `guide.downloads-cleanup` | Sort by date/size, installers, archives already extracted, duplicates; Finder views; move keepers to Documents |
| `guide.desktop-organization` | Stacks («Использовать стопки»), folders, Desktop in iCloud consideration |
| `guide.file-organization` | Simple folder structure, tags, Smart Folders, naming; personal recordings: listen before deleting |
| `guide.optimize-storage` | Системные настройки → Основные → Хранилище recommendations; iCloud Drive optimize; Photos optimize; Music/TV downloads |
| `guide.free-space-target` | Keep roughly 10–15% free (swap, updates, snapshots); why a nearly full disk slows things down |
| `guide.caches-explained` | What a cache is, why deleting is safe, why it regrows, when not to (app running, offline needs) |
| `guide.uninstall-apps` | Use SpotlessMac «Программы» to remove app + leftovers; App Store apps; apps with their own uninstallers |
| `guide.fda` | Why SpotlessMac asks for Full Disk Access; what it reads; how to grant it (Конфиденциальность и безопасность → Полный доступ к диску) |
| `guide.spotlight-exclude` | Exclude folders from Spotlight via Spotlight settings privacy list; when it helps (build folders, VMs, archives) |
| `guide.large-media` | Where big videos/archives/VM images hide; keep vs external disk vs cloud; SpotlessMac large files are review-only |

- [ ] **Step 1:** Write the guides following the shared rules (`verdict: info`, `sources` recommended even though optional).
- [ ] **Step 2:** Write `knowledge-eval-guides.json` (≥ 25 queries), e.g. `{"query": "почему системные данные занимают 80 гигабайт", "expected": "guide.system-data"}`.
- [ ] **Step 3:** Run `scripts/test.sh KnowledgeCorpusTests KnowledgeEvalTests KnowledgeMatcherTests`. Expected: PASS.
- [ ] **Step 4:** Commit (`content(knowledge): guides, wave 1`, same trailer format as Task 10).

---

### Task 13: Coverage gate, manual checklist, spec status

**Files:**
- Modify: `SpotlessMacTests/KnowledgeCorpusTests.swift`
- Modify: `docs/superpowers/plans/2026-10-02-cleanup-assistant-manual-checklist.md`
- Modify: `docs/superpowers/specs/2026-10-03-assistant-knowledge-base-design.md` (status line and §7 UI names)

**Interfaces:**
- Consumes: everything above; all content merged.
- Produces: the release gate.

- [ ] **Step 1: Add the coverage tests**

Append to `KnowledgeCorpusTests`:

```swift
    func testWaveOneIsComplete() throws {
        let ids = Set(try corpus().articles.map(\.id))
        XCTAssertEqual(Self.wave1.subtracting(ids).sorted(), [], "missing wave-1 articles")
    }

    func testEveryScanCategoryHasExactlyOneFallback() throws {
        let base = try corpus()
        for category in ScanCategory.allCases {
            let owners = base.articles.filter { $0.categories.contains(category) }.map(\.id)
            XCTAssertEqual(owners.count, 1, "\(category.rawValue): \(owners)")
        }
    }

    func testEveryArticleHasAnEvalQuery() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("knowledge-eval-") && $0.hasSuffix(".json") }
        var expected = Set<String>()
        for name in names {
            let cases = try JSONDecoder().decode([KnowledgeEvalTests.EvalCase].self,
                                                 from: Data(contentsOf: folder.appending(path: name)))
            expected.formUnion(cases.map(\.expected))
        }
        let ids = Set(try corpus().articles.map(\.id))
        XCTAssertEqual(ids.subtracting(expected).sorted(), [], "articles without eval queries")
    }
```

- [ ] **Step 2: Run the whole suite**

Run: `scripts/test.sh`
Expected: `** TEST SUCCEEDED **`; `Knowledge eval:` line shows ≥ 90%. If `testEveryScanCategoryHasExactlyOneFallback` fails, fix the `categories` of the offending articles (spec §9 lists the intended owner per category).

- [ ] **Step 3: Extend the manual checklist**

Append a section to `docs/superpowers/plans/2026-10-02-cleanup-assistant-manual-checklist.md`:

```markdown
## Knowledge base (2026-10-03)

Run each question twice — local Ollama with tools on, and with «Инструменты: Выкл» — on a Mac with a fresh scan and the «Память» tab opened once.

- [ ] «Что за процесс kernel_task и почему он грузит процессор?» — answer matches `proc.kernel-task`, no invented settings.
- [ ] «Почему Системные данные занимают так много?» — follows `guide.system-data`.
- [ ] «Как разобрать папку Загрузки?» — follows `guide.downloads-cleanup`, points to «Освободить место».
- [ ] «Можно удалить резервные копии iPhone?» — verdict «не трогать», points to Finder.
- [ ] «Chrome ест 6 ГБ памяти, что делать?» — follows `app.chrome`, mentions «Память».
- [ ] «Как убрать программы из автозагрузки?» — gives the «Объекты входа» path from `guide.login-items`.
- [ ] «Что такое mds_stores?» — tool mode calls `lookup_knowledge` (status «Читаю справку…»).
- [ ] Ask about something not in the base («как настроить принтер») — the assistant says it has no reference and answers cautiously.
- [ ] Cloud provider: request log contains article ids but no real home paths.
- [ ] Every answer above stays within the no-delete rules and contains no terminal commands.
```

- [ ] **Step 4: Update the spec**

In the spec, set `Status: implemented; aligned with the plan (Task 13)` and in §7 replace «Удаление программ» with «Программы» and «Освободить место» with «Освободить место» (вкладка «Диск»).

- [ ] **Step 5: Commit**

```bash
git add SpotlessMacTests/KnowledgeCorpusTests.swift docs/superpowers/plans/2026-10-02-cleanup-assistant-manual-checklist.md \
  docs/superpowers/specs/2026-10-03-assistant-knowledge-base-design.md
git commit -m "test(knowledge): wave-1 coverage gate and manual checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
