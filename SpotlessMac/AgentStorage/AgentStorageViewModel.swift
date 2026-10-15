import Foundation
import Observation

enum AgentStorageCleanupResult: Equatable {
    case completed(Int), busy, licenseRequired, staleSelection
}

@Observable @MainActor
final class AgentStorageViewModel {
    private(set) var report = AgentStorageReport()
    private(set) var selectedIDs = Set<String>()
    private(set) var isScanning = false
    private(set) var isDeleting = false
    private(set) var hasScanned = false
    private(set) var extraRoots = StorageRootRegistry.roots(kind: .agentWorkspaces)
    private var hasCurrentScan = false
    private(set) var failures: [DeletionFailure] = []
    private(set) var message: String?
    var query = ""
    var statusFilter: AgentStorageStatus?
    var agentFilter: String?
    private var generation = UUID()
    private var scanTask: Task<Void, Never>?
    private let scanInventory: @Sendable () async throws -> AgentStorageReport
    private let deleteItems: @Sendable ([ScanItem]) async -> [DeletionFailure]

    init(scan: @escaping @Sendable () async throws -> AgentStorageReport = { try await AgentStorageScanner().inventory() },
         delete: (@Sendable ([ScanItem]) async -> [DeletionFailure])? = nil) {
        scanInventory = scan
        let engine = ScanEngine()
        deleteItems = delete ?? { await engine.delete(items: $0) }
    }

    var isBusy: Bool { isScanning || isDeleting }
    var selectedBytes: Int64 { report.items.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var visibleItems: [AgentStorageItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return report.items.filter {
            (statusFilter == nil || $0.status == statusFilter)
                && (agentFilter == nil || $0.agent == agentFilter)
                && (search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) || $0.agent.localizedCaseInsensitiveContains(search))
        }
    }

    func startScan() {
        guard !isBusy, scanTask == nil else { return }
        scanTask = Task { await scan(); scanTask = nil }
    }
    func cancelScan() { scanTask?.cancel() }

    func scan() async {
        guard !isBusy else { return }
        isScanning = true; hasCurrentScan = false; selectedIDs = []; failures = []; message = nil; generation = UUID()
        defer { isScanning = false }
        do {
            let result = try await scanInventory()
            try Task.checkCancellation()
            report = result; hasScanned = true; hasCurrentScan = true
        } catch is CancellationError { message = "Сканирование отменено. Для очистки обновите результаты." }
        catch { message = "Сканирование не завершено: \(error.localizedDescription)" }
    }

    func toggle(_ item: AgentStorageItem) {
        guard !isBusy, hasCurrentScan, item.status == .cleanable,
              report.items.contains(where: { $0.scanItem.id == item.scanItem.id }) else { return }
        if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
    }

    func selectVisibleCandidates() {
        guard !isBusy, hasCurrentScan else { return }
        selectedIDs.formUnion(visibleItems.filter { $0.status == .cleanable }.map(\.id))
    }

    func clearSelection() { if !isBusy { selectedIDs = [] } }

    func makeSelection() -> AgentStorageSelection? {
        guard !isBusy, hasCurrentScan else { return nil }
        let items = report.items.filter { selectedIDs.contains($0.id) && $0.status == .cleanable }
        return items.isEmpty ? nil : AgentStorageSelection(generation: generation, items: items)
    }

    func addRoot(_ url: URL) {
        guard !isBusy else { return }
        do {
            try StorageRootRegistry.register(url, kind: .agentWorkspaces)
            extraRoots = StorageRootRegistry.roots(kind: .agentWorkspaces)
            startScan()
        }
        catch { message = "Выберите отдельную папку рабочих данных агента: \(error.localizedDescription)" }
    }

    func removeRoot(_ url: URL) {
        guard !isBusy else { return }
        StorageRootRegistry.unregister(url, kind: .agentWorkspaces)
        extraRoots = StorageRootRegistry.roots(kind: .agentWorkspaces)
        startScan()
    }

    func deleteConfirmed(_ selection: AgentStorageSelection, canClean: Bool,
                         recordSuccessfulClean: @MainActor () -> Void) async -> AgentStorageCleanupResult {
        guard !isBusy else { return .busy }
        guard canClean else { return .licenseRequired }
        guard selection.generation == generation, !selection.items.isEmpty,
              Set(selection.items.map(\.id)).count == selection.items.count,
              selection.items.allSatisfy({ selected in
                  report.items.contains { $0.scanItem == selected.scanItem && $0.status == .cleanable }
              }) else {
            message = "Результаты изменились. Откройте предпросмотр заново."
            return .staleSelection
        }
        isDeleting = true; failures = []; message = nil
        defer { isDeleting = false }
        failures = await deleteItems(selection.items.map(\.scanItem))
        let failed = Set(failures.map(\.item.id))
        let succeeded = selection.items.filter { !failed.contains($0.scanItem.id) }
        let removedIDs = Set(succeeded.map(\.id))
        report.items.removeAll { removedIDs.contains($0.id) }
        selectedIDs = []; generation = UUID()
        message = "В Корзину перемещено: \(succeeded.count). Место освободится после её очистки."
        if !succeeded.isEmpty { recordSuccessfulClean() }
        return .completed(succeeded.count)
    }
}
