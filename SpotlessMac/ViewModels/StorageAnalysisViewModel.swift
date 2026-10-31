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
    typealias MeasureSource = @Sendable (URL) async throws -> StorageMeasurement
    private let loadChildren: LoadChildren
    private let isDeletable: @Sendable (URL) -> Bool
    private let sources: @Sendable () -> [StorageSource]
    private let measureSource: MeasureSource
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
         isDeletable: @escaping @Sendable (URL) -> Bool = SafetyRules.isManuallyDeletable,
         sources: @escaping @Sendable () -> [StorageSource] = { StorageSourceCatalog.sources() },
         measureSource: @escaping MeasureSource = { try await StorageAnalysisEngine().measure($0) }) {
        let engine = StorageAnalysisEngine()
        self.loadChildren = loadChildren ?? { try await engine.children(of: $0) }
        self.isDeletable = isDeletable
        self.sources = sources
        self.measureSource = measureSource
    }
    /// Sources for the disk breakdown. Empty while the first pass runs: half of the sources would read as the total.
    var breakdownSources: [StorageSourceResult] { isLoading && sampledAt == nil ? [] : sourceResults }
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
        let sources = self.sources()
        let measureSource = self.measureSource
        let ids = Set(sources.map(\.id))
        // A refresh keeps the previous sizes on screen until each source is measured again.
        let previous = sourceResults.filter { ids.contains($0.id) }
        task = Task {
            var results = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var pending = sources.makeIterator()
            await withTaskGroup(of: StorageSourceResult.self) { group in
                // Up to four sources at once; a slow one no longer holds back the sources queued after it.
                for _ in 0..<4 {
                    guard let source = pending.next() else { break }
                    group.addTask { await Self.measure(source, with: measureSource) }
                }
                for await value in group {
                    guard activeScanID == id, !Task.isCancelled else { group.cancelAll(); return }
                    results[value.id] = value
                    sourceResults = results.values.sorted {
                        let (left, right) = ($0.measurement?.allocatedBytes ?? -1, $1.measurement?.allocatedBytes ?? -1)
                        return left != right ? left > right : $0.id < $1.id
                    }
                    if let source = pending.next() { group.addTask { await Self.measure(source, with: measureSource) } }
                }
            }
            if activeScanID == id, !Task.isCancelled { isLoading = false; isStale = false; sampledAt = Date() }
        }
        await task?.value
    }
    private nonisolated static func measure(_ source: StorageSource, with measureSource: MeasureSource) async -> StorageSourceResult {
        do {
            return StorageSourceResult(source: source, measurement: try await measureSource(source.url), errorMessage: nil)
        } catch {
            return StorageSourceResult(source: source, measurement: nil, errorMessage: error.localizedDescription)
        }
    }
}
