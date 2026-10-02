import Foundation

struct DeletionFailure: Sendable {
    let item: ScanItem
    let reason: String
}

enum DeletionRequestResult: Sendable {
    case completed([DeletionFailure])
    case busy
}

actor ScanEngine {
    private let activity: @Sendable (ScanItem) async -> OwnerActivity
    private let validate: @Sendable (ScanItem) -> String?
    private let trash: @Sendable (URL) throws -> Void
    init(activity: @escaping @Sendable (ScanItem) async -> OwnerActivity = OwnerActivityChecker.check,
         validate: @escaping @Sendable (ScanItem) -> String? = { CleanupPlanBuilder.validationFailure(for: $0) },
         trash: @escaping @Sendable (URL) throws -> Void = {
             guard SafetyRules.isSafe(url: $0) else { throw CocoaError(.fileWriteNoPermission) }
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.activity = activity; self.validate = validate; self.trash = trash
    }
    private func rejection(_ item: ScanItem) async -> String? {
        if let failure = validate(item) { return failure }
        if item.cleanupPolicy.requiresClosedOwner {
            switch await activity(item) {
            case .running: return "Закройте приложение или остановите загрузку/сборку перед очисткой."
            case .unknown: return "Не удалось проверить активность инструмента. Очистка остановлена."
            case .closed: break
            }
        }
        return validate(item) // Revalidate after asynchronous owner check.
    }
    func scan(fdaStatus: FDAStatus) async throws -> [ScanItem] {
        let scanners: [any Scanner] = [
            CachesScanner(),
            LogsScanner(fdaGranted: fdaStatus == .granted),
            DeveloperCachesScanner(),
            OldInstallersScanner(),
            LargeFilesScanner(),
            KnownCacheScanner(),
            ProjectArtifactsScanner(),
            RecordingScanner(),
        ] + SafetyRules.huggingFaceRoots.filter(SafetyRules.rootIsTrusted).map { HuggingFaceCacheScanner(root: $0) as any Scanner }
        var results: [ScanItem] = []
        for scanner in scanners {
            do {
                let items = try await scanner.scan()
                results.append(contentsOf: items)
            } catch {
                // A denied or unreadable source must not hide results from
                // the remaining safe roots.
                continue
            }
        }
        return ScanResultMerger.deduplicate(results)
    }

    // Non-throwing: per-item failures collected and returned.
    // Only FileManager.trashItem is used — never removeItem.
    // Review-only files must reach this method only after a per-item preview.
    func delete(items: [ScanItem]) async -> [DeletionFailure] {
        var failures = items.filter { !$0.cleanupPolicy.canDelete }.map {
            DeletionFailure(item: $0, reason: "Этот объект доступен только для просмотра.")
        }
        let confirmed = items.map { item in var item = item; item.isSelected = true; return item }
        let targets: [ScanItem]
        do { targets = try CleanupPlanBuilder.make(items: confirmed) }
        catch { return items.map { DeletionFailure(item: $0, reason: "Выбраны пересекающиеся объекты с разными правилами. Проверьте выбор.") } }
        for item in targets {
            if let reason = await rejection(item) {
                failures.append(DeletionFailure(item: item, reason: reason)); continue
            }
            do { try trash(item.path) }
            catch { failures.append(DeletionFailure(item: item, reason: error.localizedDescription)) }
        }
        let targetIDs = Set(targets.map(\.id))
        for item in items where !targetIDs.contains(item.id) && !failures.contains(where: { $0.item.id == item.id }) {
            if let parentFailure = failures.first(where: { PathPolicy.contains(PathPolicy.canonical(item.path), in: PathPolicy.canonical($0.item.path)) }) {
                failures.append(DeletionFailure(item: item, reason: parentFailure.reason))
            }
        }
        return failures
    }
}

enum ScanResultMerger {
    static func deduplicate(_ items: [ScanItem]) -> [ScanItem] {
        var result: [ScanItem] = []
        var indexByPath: [String: Int] = [:]

        for item in items {
            let key = item.path.standardizedFileURL.path(percentEncoded: false)
            if let index = indexByPath[key] {
                if result[index].category == .largeFiles && item.category == .oldInstallers {
                    result[index] = item
                }
            } else {
                indexByPath[key] = result.count
                result.append(item)
            }
        }
        return result
    }
}

enum CleaningEvent: Sendable {
    case itemProcessed(item: ScanItem, failure: DeletionFailure?)
}

extension ScanEngine {
    // Streams one event per item as it's trashed, so the UI can show a live
    // ring/current-file/per-category checklist. Every item is still gated
    // through SafetyRules.isSafe — same guarantee as delete(items:) above.
    nonisolated func deleteWithProgress(
        items: [ScanItem],
        cancellation: CleaningCancellation
    ) -> AsyncStream<CleaningEvent> {
        AsyncStream { continuation in
            let task = Task {
                for item in items {
                    if Task.isCancelled || cancellation.isCancelled { break }
                    let failure = await self.delete(items: [item]).first
                    continuation.yield(.itemProcessed(item: item, failure: failure))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
