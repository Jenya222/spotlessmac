import Foundation
import Observation

// Copies live view-model state into the assistant's immutable snapshot.
// Lives outside SpotlessMac/Assistant/ on purpose: the assistant never sees these objects.
@MainActor
enum AssistantSnapshotBuilder {
    static let maxTopProcesses = 8

    static func make(
        scan: ScanViewModel,
        docker: DockerCleanupViewModel?,
        uninstall: UninstallViewModel?,
        memory: MemorySample?,
        volume: VolumeInfo?,
        now: Date
    ) -> SystemSnapshot {
        let sorted = scan.items.sorted {
            $0.size != $1.size ? $0.size > $1.size : $0.path.path < $1.path.path
        }
        let items = sorted.enumerated().map { index, item in
            SnapshotItem(
                shortID: "c\(index + 1)", itemID: item.id, path: item.path.path(percentEncoded: false),
                bytes: item.size, category: item.category, disposition: item.cleanupPolicy.disposition,
                reason: item.cleanupReason, modifiedAt: item.modifiedAt, owner: item.owner
            )
        }
        let categories = Dictionary(grouping: items, by: \.category)
            .map { CategorySummary(category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.category.rawValue < $1.category.rawValue }
        let fda: Bool? = switch scan.fdaStatus {
        case .granted: true
        case .denied: false
        case .unknown: nil
        }
        return SystemSnapshot(
            takenAt: now,
            volume: volume,
            fullDiskAccess: fda,
            lastScanAt: scan.lastScanAt,
            categories: categories,
            items: items,
            docker: docker.flatMap { dockerInfo($0) },
            leftovers: uninstall.flatMap { leftoverInfo($0) },
            lastCleanup: scan.cleanupReport.map {
                LastCleanupInfo(trashedBytes: $0.trashedBytes, observedFreeSpaceDelta: $0.observedFreeSpaceDelta)
            },
            memory: memory.map { memoryInfo($0) }
        )
    }

    static func memoryInfo(_ sample: MemorySample) -> MemoryInfo {
        let load: MemoryLoad = switch sample.system.pressure {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        case .unknown: .unknown
        }
        let topApps = sample.groups
            .filter { $0.kind == .userApp }
            .sorted { $0.footprint > $1.footprint }
            .prefix(5)
            .map { group in
                MemoryAppInfo(name: group.displayName, bytes: Int64(clamping: group.footprint),
                              bundleID: sample.runningApps(in: group).compactMap(\.bundleIdentifier).first)
            }
        let topProcesses = sample.groups
            .filter { $0.kind != .userApp }
            .flatMap(\.processes)
            .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
            .prefix(maxTopProcesses)
            .map { MemoryProcessInfo(name: $0.name, bytes: Int64(clamping: $0.footprint)) }
        return MemoryInfo(
            load: load,
            usedBytes: Int64(clamping: sample.system.used),
            physicalBytes: Int64(clamping: sample.system.physical),
            swapUsedBytes: Int64(clamping: sample.system.swapUsed),
            topApps: Array(topApps),
            topProcesses: Array(topProcesses)
        )
    }

    static func readVolume() -> VolumeInfo? {
        let root = URL(filePath: "/", directoryHint: .isDirectory)
        guard let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]),
              let total = values.volumeTotalCapacity else { return nil }
        return VolumeInfo(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            totalBytes: Int64(total),
            availableBytes: Int64(values.volumeAvailableCapacity ?? 0)
        )
    }

    static func focus(for item: ScanItem, ownerActivity: OwnerActivity?) -> AssistantFocus {
        var facts = [
            "Категория: \(item.category.displayName)",
            "Размер: \(item.formattedSize)",
            "Политика: \(item.cleanupPolicy.disposition.label)",
            "Причина: \(item.cleanupReason)",
        ]
        if let modified = item.modifiedAt { facts.append("Изменён: \(SnapshotRenderer.date(modified))") }
        if let owner = item.owner {
            facts.append("Владелец: \(owner)\(ownerActivity == .running ? " (сейчас запущен)" : "")")
        }
        return AssistantFocus(title: item.path.lastPathComponent, path: item.path.path(percentEncoded: false), facts: facts)
    }

    static func focus(for leftover: LeftoverItem, appName: String?) -> AssistantFocus {
        var facts = [
            "Расположение: \(leftover.location)",
            "Тип: \(leftover.dispositionLabel)",
            "Размер: \(leftover.formattedSize)",
            leftover.confidence == .exact
                ? "Совпадение: точное, по идентификатору программы"
                : "Совпадение: только по имени — возможно, не связано с программой",
        ]
        if let appName { facts.insert("Остаток программы «\(appName)»", at: 0) }
        return AssistantFocus(title: leftover.path.lastPathComponent, path: leftover.path.path(percentEncoded: false), facts: facts)
    }

    static func focus(for resource: DockerResource) -> AssistantFocus {
        let risk = switch resource.risk {
        case .rebuildable: "восстановимо (пересоздаётся при сборке или загрузке)"
        case .review: "проверьте перед удалением"
        case .dataLoss: "риск потери данных"
        }
        var facts = ["Тип: \(resource.kind.displayName)", "Описание: \(resource.detail)", "Размер: \(resource.formattedSize)", "Риск: \(risk)"]
        if let used = resource.lastUsedAt ?? resource.createdAt { facts.append("Последнее использование: \(SnapshotRenderer.date(used))") }
        return AssistantFocus(title: resource.name, path: "Docker: \(resource.kind.displayName)", facts: facts)
    }

    private static func dockerInfo(_ viewModel: DockerCleanupViewModel) -> DockerInfo? {
        let status: String
        switch viewModel.availability {
        case .checking: return nil
        case .cliMissing: status = "Docker CLI не установлен"
        case .daemonUnavailable: status = "Docker не запущен"
        case .ready: status = "Docker запущен"
        }
        let kinds = DockerResourceKind.allCases.compactMap { kind -> DockerKindSummary? in
            let resources = viewModel.resources.filter { $0.kind == kind }
            guard !resources.isEmpty else { return nil }
            return DockerKindSummary(
                kindName: kind.displayName, count: resources.count,
                bytes: resources.compactMap(\.size).reduce(0, +),
                dataLossCount: resources.filter { $0.risk == .dataLoss }.count
            )
        }
        return DockerInfo(
            status: status,
            virtualDiskBytes: viewModel.storageSummary.virtualDiskAllocatedBytes,
            reclaimableBytes: viewModel.storageSummary.engineReclaimableBytes,
            kinds: kinds
        )
    }

    private static func leftoverInfo(_ viewModel: UninstallViewModel) -> LeftoverInfo? {
        guard let app = viewModel.selectedApp, !viewModel.leftovers.isEmpty else { return nil }
        let leftovers = viewModel.leftovers
        return LeftoverInfo(
            appName: app.name, count: leftovers.count,
            exactCount: leftovers.filter { $0.confidence == .exact }.count,
            nameOnlyCount: leftovers.filter { $0.confidence == .nameOnly }.count,
            bytes: leftovers.reduce(0) { $0 + $1.size }
        )
    }
}

// Latest read-only memory sample for the assistant's context (independent of the Memory tab's polling).
@Observable
@MainActor
final class AssistantMemoryCache {
    private(set) var latest: MemorySample?
    private let sample: @Sendable () async -> MemorySample

    init(sample: @escaping @Sendable () async -> MemorySample = AssistantMemoryCache.liveSample) {
        self.sample = sample
    }

    // Nonisolated so the process scan hops off the main actor into MemoryMonitor.
    nonisolated private static func liveSample() async -> MemorySample {
        await MemoryMonitor().sample()
    }

    func refresh() async {
        latest = await sample()
    }
}
