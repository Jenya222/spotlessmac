import Foundation

struct ScanItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let category: ScanCategory
    var isSelected: Bool

    init(path: URL, size: Int64, category: ScanCategory, isSelected: Bool = true) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.category = category
        self.isSelected = isSelected
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
