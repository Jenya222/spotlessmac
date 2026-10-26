import Foundation
import Observation

struct StorageSourceResult: Identifiable, Sendable {
    let source: StorageSource
    let measurement: StorageMeasurement?
    let errorMessage: String?
    var id: String { source.id }
}

@Observable @MainActor
final class StorageAnalysisViewModel {
    typealias LoadChildren = @Sendable (URL) async throws -> [StorageNode]
    private let loadChildren: LoadChildren
    private let isDeletable: @Sendable (URL) -> Bool
    private var task: Task<Void, Never>?
    private var activeScanID: UUID?
    var nodes: [StorageNode] = []
    // Evaluated together with `nodes`, so the two always describe the same snapshot.
    private(set) var deletableNodeIDs: Set<String> = []
    var sourceResults: [StorageSourceResult] = []
    var isLoading = false
    var isStale = false
    var errorMessage: String?
    var sampledAt: Date?

    init(loadChildren: LoadChildren? = nil,
         isDeletable: @escaping @Sendable (URL) -> Bool = SafetyRules.isManuallyDeletable) {
        let engine = StorageAnalysisEngine()
        self.loadChildren = loadChildren ?? { try await engine.children(of: $0) }
        self.isDeletable = isDeletable
    }
    func cancel() {
        task?.cancel(); task = nil; activeScanID = nil
        isLoading = false; isStale = true
    }
    func scan(root: URL) async {
        task?.cancel()
        let id = UUID(); activeScanID = id; isLoading = true; errorMessage = nil
        let load = loadChildren
        let isDeletable = isDeletable
        task = Task {
            do {
                let result = try await load(root)
                let deletable = try await StorageAnalysisEngine.offMain { Set(result.filter { isDeletable($0.url) }.map(\.id)) }
                guard activeScanID == id, !Task.isCancelled else { return }
                nodes = result; deletableNodeIDs = deletable; sampledAt = Date(); isStale = false
            } catch {
                guard activeScanID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription; isStale = true
            }
            if activeScanID == id { isLoading = false }
        }
        await task?.value
    }
    /// Trash confirmation snapshot: identities are captured now and re-checked by the engine,
    /// which only knows `isSafe`, so the stricter manual rule is re-applied here.
    func deletionItems(for ids: Set<String>) -> [ScanItem] {
        nodes.filter { ids.contains($0.id) && deletableNodeIDs.contains($0.id) && isDeletable($0.url) }.map {
            ScanItem(path: $0.url, size: $0.measurement.allocatedBytes, category: .largeFiles, isSelected: true,
                     cleanupPolicy: CleanupPolicy(disposition: .personalData, reason: "Выбрано вручную в обзоре диска.", requiresClosedOwner: false))
        }
    }
    func scanSources() async {
        task?.cancel()
        let id = UUID(); activeScanID = id; isLoading = true; errorMessage = nil
        let sources = StorageSourceCatalog.sources()
        task = Task {
            var results: [StorageSourceResult] = []
            for offset in stride(from: 0, to: sources.count, by: 4) {
                guard activeScanID == id, !Task.isCancelled else { return }
                let batch = Array(sources[offset..<min(sources.count, offset + 4)])
                let partial = await withTaskGroup(of: StorageSourceResult.self) { group in
                    for source in batch {
                        group.addTask {
                            do {
                                let measurement = try await StorageAnalysisEngine().measure(source.url)
                                return StorageSourceResult(source: source, measurement: measurement, errorMessage: nil)
                            } catch {
                                return StorageSourceResult(source: source, measurement: nil, errorMessage: error.localizedDescription)
                            }
                        }
                    }
                    var values: [StorageSourceResult] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard activeScanID == id, !Task.isCancelled else { return }
                results.append(contentsOf: partial)
                sourceResults = results.sorted { ($0.measurement?.allocatedBytes ?? -1) > ($1.measurement?.allocatedBytes ?? -1) }
            }
            if activeScanID == id { isLoading = false; isStale = false; sampledAt = Date() }
        }
        await task?.value
    }
}
