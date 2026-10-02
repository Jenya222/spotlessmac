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
        for name in ["delete_file", "trash", "run_shell", "rm", "exec", "quit_app", "kill_process"] {
            let outcome = AssistantToolbox.execute(ToolCall(id: "x", name: name, argumentsJSON: "{}"), snapshot: .sample()) { $0 }
            XCTAssertNil(outcome.proposal, name)
            XCTAssertTrue(outcome.resultText.contains("не существует"), name)
        }
    }
}
