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
    ]
    private let allowances: [String: Set<String>] = ["ConversationStore.swift": ["FileManager"]]
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
        XCTAssertGreaterThanOrEqual(files.count, 18, "Assistant sources not found")
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
            "homePath", "refreshContext", "now",
        ])
        XCTAssertEqual(labels.count, 9)
    }

    func testToolSetIsClosedAndReadOnly() {
        XCTAssertEqual(AssistantTool.names, ["list_items", "item_details", "propose_plan"])
        XCTAssertEqual(AssistantTool.specs.map(\.name), AssistantTool.names)
        for name in ["delete_file", "trash", "run_shell", "rm", "exec", "quit_app", "kill_process"] {
            let call = ToolCall(id: "x", name: name, argumentsJSON: "{}")
            XCTAssertEqual(AssistantTool.parse(call), .failure(.unknownTool(name)), name)
            let outcome = AssistantToolbox.execute(call, snapshot: .sample()) { $0 }
            XCTAssertNil(outcome.proposal, name)
        }
    }
}
