import Foundation

struct Improvement: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case ask(String)
        case scan
    }

    let id: String
    let icon: String
    let title: String
    let detail: String
    let action: Action
}

// Local, LLM-free "what can be improved" list for the assistant tab.
enum ImprovementAdvisor {
    static let gigabyte: Int64 = 1_000_000_000
    static let maxSuggestions = 6
    static let advisable: Set<ScanCategory> = [
        .userCaches, .developerCaches, .logs, .modelCaches, .knownAppCaches, .projectArtifacts, .oldInstallers,
    ]

    static func suggestions(for snapshot: SystemSnapshot) -> [Improvement] {
        var weighted: [(weight: Int64, improvement: Improvement)] = []
        if let volume = snapshot.volume, volume.freeFraction < 0.1 {
            weighted.append((Int64.max, Improvement(
                id: "low-space", icon: "exclamationmark.triangle.fill",
                title: "Мало свободного места: \(SnapshotRenderer.percent(volume.freeFraction))",
                detail: "Свободно \(SnapshotRenderer.bytes(volume.availableBytes)) из \(SnapshotRenderer.bytes(volume.totalBytes))",
                action: .ask("Почему диск заполнен и что освободить в первую очередь?")
            )))
        }
        if let memory = snapshot.memory,
           memory.load == .warning || memory.load == .critical || memory.swapUsedBytes >= gigabyte {
            let title = switch memory.load {
            case .critical: "Критическая нехватка памяти"
            case .warning: "Высокое давление памяти"
            default: "Используется своп: \(SnapshotRenderer.memoryBytes(memory.swapUsedBytes))"
            }
            weighted.append((Int64.max - 1, Improvement(
                id: "memory", icon: "memorychip", title: title,
                detail: "Занято \(SnapshotRenderer.memoryBytes(memory.usedBytes)) из \(SnapshotRenderer.memoryBytes(memory.physicalBytes))",
                action: .ask("Почему не хватает памяти и какие программы стоит закрыть?")
            )))
        }
        if snapshot.fullDiskAccess == false {
            weighted.append((Int64.max - 1, Improvement(
                id: "fda", icon: "lock.shield",
                title: "Нет полного доступа к диску",
                detail: "Часть системных кешей и логов не видна",
                action: .ask("Зачем SpotlessMac нужен полный доступ к диску и что без него не найдётся?")
            )))
        }
        guard let scanDate = snapshot.lastScanAt else {
            weighted.append((Int64.max - 2, Improvement(
                id: "scan", icon: "magnifyingglass",
                title: "Сканирование ещё не проводилось",
                detail: "Запустите поиск, чтобы ассистент видел кеши и крупные файлы",
                action: .scan
            )))
            return Array(weighted.sorted { $0.weight > $1.weight }.map(\.improvement).prefix(maxSuggestions))
        }
        if snapshot.takenAt.timeIntervalSince(scanDate) > 3 * 86_400 {
            weighted.append((Int64.max - 3, Improvement(
                id: "stale-scan", icon: "clock.arrow.circlepath",
                title: "Результаты сканирования устарели",
                detail: "Последнее сканирование: \(SnapshotRenderer.date(scanDate))",
                action: .scan
            )))
        }
        for summary in snapshot.categories where summary.bytes >= gigabyte && advisable.contains(summary.category) {
            weighted.append((summary.bytes, Improvement(
                id: "category-\(summary.category.rawValue)", icon: "folder.badge.minus",
                title: "\(summary.category.displayName): \(SnapshotRenderer.bytes(summary.bytes))",
                detail: "\(summary.count) элементов",
                action: .ask("Что из категории «\(summary.category.displayName)» можно безопасно удалить?")
            )))
        }
        if let docker = snapshot.docker, let reclaimable = docker.reclaimableBytes, reclaimable >= gigabyte {
            weighted.append((reclaimable, Improvement(
                id: "docker", icon: "shippingbox",
                title: "Docker: можно освободить \(SnapshotRenderer.bytes(reclaimable))",
                detail: docker.status,
                action: .ask("Что можно безопасно удалить из Docker?")
            )))
        }
        if let leftovers = snapshot.leftovers, leftovers.count > 0 {
            weighted.append((leftovers.bytes, Improvement(
                id: "leftovers", icon: "trash.slash",
                title: "Остатки «\(leftovers.appName)»: \(SnapshotRenderer.bytes(leftovers.bytes))",
                detail: "\(leftovers.count) элементов",
                action: .ask("Какие остатки программы «\(leftovers.appName)» можно удалить?")
            )))
        }
        return Array(weighted.sorted { $0.weight > $1.weight }.map(\.improvement).prefix(maxSuggestions))
    }
}
