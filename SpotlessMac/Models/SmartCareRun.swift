import Foundation

struct CategoryTotal: Identifiable, Sendable {
    let category: ScanCategory
    let totalBytes: Int64
    var id: String { category.rawValue }
}

struct SmartCareRun: Identifiable, Sendable {
    let id: UUID
    let items: [ScanItem]
    let totalBytes: Int64
    let categoryTotals: [CategoryTotal]

    init(id: UUID = UUID(), items: [ScanItem]) {
        self.id = id
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.size }
        let grouped = Dictionary(grouping: items, by: \.category)
        self.categoryTotals = grouped
            .map { CategoryTotal(category: $0.key, totalBytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
}
