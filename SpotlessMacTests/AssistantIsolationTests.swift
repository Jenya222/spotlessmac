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
        // Memory section (quits apps): the assistant must not reach it either.
        "MemoryViewModel", "AppTerminator", "NSRunningApplication", "terminate(", "forceTerminate", "kill(",
        // Other ways to spawn processes or mutate files. A bare "system(" is deliberately absent:
        // it collides with AssistantPrompt.system(toolsEnabled:).
        "posix_spawn", "NSAppleScript", "popen(", "rmdir(", "FileHandle", "replaceItem", "createFile(",
        "Darwin.system", "NSTask",
        // Low-level deletion and write paths. Any "Darwin." access is refused; the only file the assistant
        // may write is its own conversation, through ConversationStore.
        "unlinkat", "removefile", "Darwin.", ".write(to:", ".write(toFile:",
    ]
    private let allowances: [String: Set<String>] = [
        "ConversationStore.swift": ["FileManager", ".write(to:"],
    ]
    private let allowedImports: Set<String> = ["Foundation", "Observation", "os"]
    private let allowedFileManagerMembers: Set<String> = ["urls", "createDirectory", "homeDirectoryForCurrentUser"]

    // Every regular file under SpotlessMac/Assistant, at any depth and with any extension.
    private var assistantSources: [URL] {
        get throws {
            let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "SpotlessMac/Assistant")
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            var files: [URL] = []
            for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files.append(url)
                }
            }
            return files
        }
    }

    func testAssistantModuleHasNoAccessToDeletionOrProcessAPIs() throws {
        let files = try assistantSources
        XCTAssertGreaterThanOrEqual(files.count, 24, "Assistant sources not found")
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

    // `Process(` is in the token list; this also catches `Process.run`, a bare `Process` type and aliases.
    func testAssistantModuleNeverMentionsTheProcessType() throws {
        let regex = try NSRegularExpression(pattern: #"\bProcess\b(?!Info)"#)
        var violations: [String] = []
        for file in try assistantSources {
            let source = try String(contentsOf: file, encoding: .utf8)
            if regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                violations.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(violations, [], "Assistant must not name Process")
    }

    // Foundation, Observation and os cannot spawn processes or reach the file system beyond what the token
    // checks watch; any other module (AppKit, Darwin, Security, ...) needs a deliberate decision here.
    func testAssistantModuleImportsOnlyApprovedModules() throws {
        let regex = try NSRegularExpression(
            pattern: #"(?:^|;)[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_]\w*)"#,
            options: .anchorsMatchLines)
        var found = Set<String>()
        var violations: [String] = []
        for file in try assistantSources {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let module = String(source[range])
                found.insert(module)
                if !allowedImports.contains(module) { violations.append("\(file.lastPathComponent): import \(module)") }
            }
        }
        XCTAssertFalse(found.isEmpty, "no imports found: the pattern is broken")
        XCTAssertEqual(violations, [], "Assistant may import only \(allowedImports.sorted())")
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
        // Every mention of FileManager must be a direct `FileManager.default.<member>` call:
        // aliases (`let fm = FileManager.default`) and line-broken uses would dodge the member check.
        let mentions = source.components(separatedBy: "FileManager").count - 1
        XCTAssertEqual(mentions, members.count, "Only direct FileManager.default.<member> uses are allowed")
    }

    // The view model receives exactly these capabilities and nothing else.
    @MainActor
    func testViewModelDependenciesExposeOnlyTheApprovedCapabilities() {
        let dependencies = AssistantViewModel.Dependencies(
            settingsStore: AssistantSettingsStore(defaults: makeDefaults()),
            keyStore: FakeKeyStore(),
            makeClient: { _, _ in FakeLLMClient([]) },
            snapshot: { .sample() },
            stagePlan: { _ in true },
            conversationStore: nil,
            homePath: SystemSnapshot.testHome)
        let labels = Mirror(reflecting: dependencies).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), [
            "settingsStore", "keyStore", "makeClient", "snapshot", "stagePlan", "conversationStore",
            "homePath", "personalRoots", "knowledge", "refreshContext", "now",
        ])
        XCTAssertEqual(labels.count, 11)
    }

    func testToolSetIsClosedAndReadOnly() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan", "lookup_knowledge"])
        XCTAssertEqual(AssistantTool.specs.map(\.name), AssistantTool.names)
        for name in ["delete_file", "trash", "run_shell", "rm", "exec", "quit_app", "kill_process"] {
            let call = ToolCall(id: "x", name: name, argumentsJSON: "{}")
            XCTAssertEqual(AssistantTool.parse(call), .failure(.unknownTool(name)), name)
            let outcome = AssistantToolbox.execute(call, snapshot: .sample()) { $0 }
            XCTAssertNil(outcome.proposal, name)
        }
    }
}
