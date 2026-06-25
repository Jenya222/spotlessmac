import Foundation

protocol Scanner: Sendable {
    var category: ScanCategory { get }
    func scan() async throws -> [ScanItem]
}
