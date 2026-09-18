import Foundation

enum DockerResourceKind: Int, CaseIterable, Identifiable, Sendable {
    case buildCache
    case image
    case container
    case volume

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .buildCache: "Кеш сборки"
        case .image: "Неиспользуемые образы"
        case .container: "Остановленные контейнеры"
        case .volume: "Неиспользуемые volumes"
        }
    }
}

enum DockerRisk: Sendable {
    case rebuildable
    case review
    case dataLoss
}

enum DockerAvailability: Equatable, Sendable {
    case checking
    case ready(serverVersion: String?)
    case cliMissing
    case daemonUnavailable(message: String)
}

struct DockerResource: Identifiable, Hashable, Sendable {
    let id: String
    let kind: DockerResourceKind
    let name: String
    let detail: String
    let size: Int64?
    let createdAt: Date?
    let lastUsedAt: Date?
    let risk: DockerRisk
    var isSelected: Bool

    var formattedSize: String {
        guard let size else { return "Размер неизвестен" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct DockerScanSnapshot: Sendable {
    var resources: [DockerResource]
    let referencedImageIDs: Set<String>
    let stoppedContainerIDs: Set<String>
    let unreferencedImageIDs: Set<String>
    let danglingVolumeNames: Set<String>
    let reclaimableBuildCacheIDs: Set<String>
}
