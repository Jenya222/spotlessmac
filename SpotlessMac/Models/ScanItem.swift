import Foundation

struct ScanItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let category: ScanCategory
    let modifiedAt: Date?
    var isSelected: Bool

    init(
        path: URL,
        size: Int64,
        category: ScanCategory,
        modifiedAt: Date? = nil,
        isSelected: Bool = true
    ) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.category = category
        self.modifiedAt = modifiedAt
        self.isSelected = isSelected
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var cleanupReason: String { category.cleanupReason }
}
