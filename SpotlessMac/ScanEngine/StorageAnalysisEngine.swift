import Foundation

actor StorageAnalysisEngine {
    let policy: PathPolicy
    private let workerObserver: @Sendable (Bool) -> Void
    init(policy: PathPolicy = StorageSourceCatalog.policy, workerObserver: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.policy = policy; self.workerObserver = workerObserver
    }

    func measure(_ url: URL) async throws -> StorageMeasurement {
        let policy = self.policy
        return try await Self.offMain {
            try StorageAnalysisEngine.measureNow(url, policy: policy)
        }
    }

    func children(of url: URL) async throws -> [StorageNode] {
        guard policy.canRead(url), let identity = StorageFileIdentity.read(url), !identity.isSymbolicLink else {
            throw CocoaError(.fileReadNoPermission)
        }
        let policy = self.policy
        let observe = workerObserver
        return try await Self.offMain {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])
            var nodes: [StorageNode] = []
            // Batches bound active sizing workers; no task per recursive file.
            for offset in stride(from: 0, to: urls.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(urls[offset..<min(offset + 4, urls.count)])
                let values = try await withThrowingTaskGroup(of: StorageNode?.self) { group in
                    for child in batch {
                        group.addTask {
                            observe(true); defer { observe(false) }
                            try Task.checkCancellation()
                            guard policy.canRead(child), let identity = StorageFileIdentity.read(child), !identity.isSymbolicLink else { return nil }
                            let values = try? child.resourceValues(forKeys: [.isPackageKey])
                            let size: StorageMeasurement
                            do { size = try StorageAnalysisEngine.measureNow(child, policy: policy) }
                            catch is CancellationError { throw CancellationError() }
                            catch { size = StorageMeasurement(unreadableEntries: 1, isComplete: false) }
                            return StorageNode(url: child, measurement: size, isDirectory: identity.isDirectory, isPackage: values?.isPackage == true)
                        }
                    }
                    var result: [StorageNode] = []
                    for try await node in group { if let node { result.append(node) } }
                    return result
                }
                nodes.append(contentsOf: values)
            }
            return nodes.sorted { $0.measurement.allocatedBytes > $1.measurement.allocatedBytes }
        }
    }

    nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    nonisolated static func measureNow(_ url: URL, policy: PathPolicy) throws -> StorageMeasurement {
        try Task.checkCancellation()
        guard policy.canRead(url), let rootID = StorageFileIdentity.read(url), !rootID.isSymbolicLink else { throw CocoaError(.fileReadNoPermission) }
        var result = StorageMeasurement()
        var seen: Set<StorageFileIdentity> = []
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func add(_ file: URL, identity: StorageFileIdentity) {
            guard identity.isRegularFile, seen.insert(identity).inserted else { return }
            do {
                let values = try file.resourceValues(forKeys: keys)
                result.logicalBytes += Int64(values.fileSize ?? 0)
                if let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                    result.allocatedBytes += Int64(bytes)
                } else { result.isComplete = false; result.unreadableEntries += 1 }
            } catch { result.isComplete = false; result.unreadableEntries += 1 }
        }
        if rootID.isRegularFile { add(url, identity: rootID); return result }
        guard rootID.isDirectory else { throw CocoaError(.fileReadUnsupportedScheme) }
        // contentsOfDirectory distinguishes unreadable/missing from an empty directory.
        _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
            result.isComplete = false; result.unreadableEntries += 1; return true
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in walker {
            try Task.checkCancellation()
            guard let identity = StorageFileIdentity.read(file) else { result.isComplete = false; result.unreadableEntries += 1; continue }
            if identity.isSymbolicLink || !policy.canRead(file) { walker.skipDescendants(); continue }
            add(file, identity: identity)
        }
        return result
    }
}
