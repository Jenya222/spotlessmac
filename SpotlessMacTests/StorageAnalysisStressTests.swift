import XCTest
@testable import SpotlessMac
private final class WorkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    func observe(_ started: Bool) { lock.lock(); defer { lock.unlock() }; active += started ? 1 : -1; peak = max(peak, active) }
}
final class StorageAnalysisStressTests: XCTestCase {
    func testLargeTreeBoundsWorkersAndSupportsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for batch in 0..<8 {
            let folder = root.appending(path: "batch-\(batch)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<6250 { try Data().write(to: folder.appending(path: "file-\(index)")) }
        }
        let counter = WorkerCounter()
        let engine = StorageAnalysisEngine(policy: PathPolicy(readRoots: [root]), workerObserver: counter.observe)
        let nodes = try await engine.children(of: root)
        XCTAssertEqual(nodes.count, 8)
        XCTAssertTrue(nodes.allSatisfy { $0.measurement.isComplete })
        XCTAssertGreaterThan(counter.peak, 0)
        XCTAssertLessThanOrEqual(counter.peak, 4)
        let task = Task { try await engine.measure(root) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
