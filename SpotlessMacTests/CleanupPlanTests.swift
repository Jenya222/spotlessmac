import XCTest
@testable import SpotlessMac
final class CleanupPlanTests: XCTestCase {
    func testDeduplicatesAndRemovesChild() throws {
        let parent = ScanItem(path: URL(filePath: "/tmp/fixture/cache"), size: 100, category: .userCaches)
        let child = ScanItem(path: URL(filePath: "/tmp/fixture/cache/child"), size: 20, category: .userCaches)
        let plan = try CleanupPlanBuilder.make(items: [parent, parent, child])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.size, 100)
    }
    func testInspectOnlyCannotBeDeleted() throws {
        let item = ScanItem(path: URL(filePath: "/tmp/fixture/important"), size: 100, category: .knownAppCaches,
                           cleanupPolicy: .init(disposition: .inspectOnly, reason: "Data", requiresClosedOwner: true))
        XCTAssertTrue(try CleanupPlanBuilder.make(items: [item]).isEmpty)
    }
    func testNewCategoriesNeverEnterSmartCare() async {
        await MainActor.run {
            let vm = ScanViewModel()
            vm.items = [.modelCaches, .projectArtifacts, .recordings, .knownAppCaches].map {
                ScanItem(path: URL(filePath: "/tmp/\($0.rawValue)"), size: 100, category: $0, isSelected: true)
            }
            XCTAssertTrue(vm.smartCareSelectedItems.isEmpty)
        }
    }
}
