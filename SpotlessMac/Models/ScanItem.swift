import Foundation

struct ScanItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let category: ScanCategory
    let modifiedAt: Date?
    var isSelected: Bool
    let cleanupPolicy: CleanupPolicy
    let identity: StorageFileIdentity?
    let owner: String?

    init(
        path: URL,
        size: Int64,
        category: ScanCategory,
        modifiedAt: Date? = nil,
        isSelected: Bool = true,
        cleanupPolicy: CleanupPolicy? = nil,
        owner: String? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.category = category
        self.modifiedAt = modifiedAt
        self.isSelected = isSelected
        self.cleanupPolicy = cleanupPolicy ?? CleanupPolicy(disposition: category.isBatchCleanable ? .rebuildable : .personalData, reason: category.cleanupReason, requiresClosedOwner: false)
        self.identity = StorageFileIdentity.read(path)
        self.owner = owner
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var cleanupReason: String { cleanupPolicy.reason }
}
