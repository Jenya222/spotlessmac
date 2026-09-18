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

struct DockerContextIdentity: Equatable, Sendable {
    let name: String
    let endpoint: String
}

struct DockerBuildxIdentity: Equatable, Sendable {
    let name: String
    let driver: String
    let nodeIdentities: Set<String>
}

struct DockerScanSnapshot: Sendable {
    var resources: [DockerResource]
    let referencedImageIDs: Set<String>
    let stoppedContainerIDs: Set<String>
    let unreferencedImageIDs: Set<String>
    let danglingVolumeNames: Set<String>
    let reclaimableBuildCacheIDs: Set<String>
    let dockerContext: DockerContextIdentity?
    let buildxBuilder: DockerBuildxIdentity?

    init(
        resources: [DockerResource],
        referencedImageIDs: Set<String>,
        stoppedContainerIDs: Set<String>,
        unreferencedImageIDs: Set<String>,
        danglingVolumeNames: Set<String>,
        reclaimableBuildCacheIDs: Set<String>,
        dockerContext: DockerContextIdentity? = nil,
        buildxBuilder: DockerBuildxIdentity? = nil
    ) {
        self.resources = resources
        self.referencedImageIDs = referencedImageIDs
        self.stoppedContainerIDs = stoppedContainerIDs
        self.unreferencedImageIDs = unreferencedImageIDs
        self.danglingVolumeNames = danglingVolumeNames
        self.reclaimableBuildCacheIDs = reclaimableBuildCacheIDs
        self.dockerContext = dockerContext
        self.buildxBuilder = buildxBuilder
    }
}
