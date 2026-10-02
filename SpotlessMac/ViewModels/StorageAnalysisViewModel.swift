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
    private var task: Task<Void, Never>?
    private var activeScanID: UUID?
    var nodes: [StorageNode] = []
    var sourceResults: [StorageSourceResult] = []
    var isLoading = false
    var isStale = false
    var errorMessage: String?
    var sampledAt: Date?

    init(loadChildren: LoadChildren? = nil) {
        let engine = StorageAnalysisEngine()
        self.loadChildren = loadChildren ?? { try await engine.children(of: $0) }
    }
    func cancel() {
        task?.cancel(); task = nil; activeScanID = nil
        isLoading = false; isStale = true
    }
    func scan(root: URL) async {
        task?.cancel()
        let id = UUID(); activeScanID = id; isLoading = true; errorMessage = nil
        let load = loadChildren
        task = Task {
            do {
                let result = try await load(root)
                guard activeScanID == id, !Task.isCancelled else { return }
                nodes = result; sampledAt = Date(); isStale = false
            } catch {
                guard activeScanID == id, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription; isStale = true
            }
            if activeScanID == id { isLoading = false }
        }
        await task?.value
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
