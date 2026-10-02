import Foundation

extension CleanupDisposition {
    var code: String {
        switch self {
        case .rebuildable: "rebuildable"
        case .redownload: "redownload"
        case .personalData: "personalData"
        case .inspectOnly: "inspectOnly"
        }
    }
}

struct SnapshotItem: Equatable, Sendable {
    let shortID: String
    let itemID: UUID
    let path: String
    let bytes: Int64
    let category: ScanCategory
    let disposition: CleanupDisposition
    let reason: String
    let modifiedAt: Date?
    let owner: String?

    var isBatchCleanable: Bool { category.isBatchCleanable }
}

struct CategorySummary: Equatable, Sendable {
    let category: ScanCategory
    let bytes: Int64
    let count: Int
}

struct VolumeInfo: Equatable, Sendable {
    var name: String
    let totalBytes: Int64
    let availableBytes: Int64

    var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
}

struct DockerKindSummary: Equatable, Sendable {
    let kindName: String
    let count: Int
    let bytes: Int64
    let dataLossCount: Int
}

struct DockerInfo: Equatable, Sendable {
    let status: String
    let virtualDiskBytes: Int64?
    let reclaimableBytes: Int64?
    let kinds: [DockerKindSummary]
}

struct LeftoverInfo: Equatable, Sendable {
    let appName: String
    let count: Int
    let exactCount: Int
    let nameOnlyCount: Int
    let bytes: Int64
}

struct LastCleanupInfo: Equatable, Sendable {
    let trashedBytes: Int64
    let observedFreeSpaceDelta: Int64?
}

enum MemoryLoad: String, Equatable, Sendable {
    case normal, warning, critical, unknown

    var label: String {
        switch self {
        case .normal: "нормальное"
        case .warning: "высокое"
        case .critical: "критическое"
        case .unknown: "неизвестно"
        }
    }
}

struct MemoryAppInfo: Equatable, Sendable {
    let name: String
    let bytes: Int64
}

// Read-only memory context. Quitting apps is never available to the assistant.
struct MemoryInfo: Equatable, Sendable {
    let load: MemoryLoad
    let usedBytes: Int64
    let physicalBytes: Int64
    let swapUsedBytes: Int64
    let topApps: [MemoryAppInfo]
}

// Immutable copy of what the assistant may know. Holds no references to live objects.
struct SystemSnapshot: Equatable, Sendable {
    var takenAt: Date
    var volume: VolumeInfo?
    var fullDiskAccess: Bool?
    var lastScanAt: Date?
    var categories: [CategorySummary] = []
    var items: [SnapshotItem] = []
    var docker: DockerInfo?
    var leftovers: LeftoverInfo?
    var lastCleanup: LastCleanupInfo?
    var memory: MemoryInfo?

    var hasScan: Bool { lastScanAt != nil }

    func item(shortID: String) -> SnapshotItem? {
        items.first { $0.shortID == shortID }
    }
}

struct AssistantFocus: Equatable, Sendable {
    let title: String
    let path: String
    let facts: [String]
}
