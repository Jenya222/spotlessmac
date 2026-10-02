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
