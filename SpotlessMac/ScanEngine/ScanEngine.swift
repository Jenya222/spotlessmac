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
    func scan(fdaStatus: FDAStatus) async throws -> [ScanItem] {
        let scanners: [any Scanner] = [
            CachesScanner(),
            LogsScanner(fdaGranted: fdaStatus == .granted),
            DeveloperCachesScanner(),
            OldInstallersScanner(),
            LargeFilesScanner(),
        ]
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
        var failures: [DeletionFailure] = []
        let fm = FileManager.default
        for item in items {
            guard SafetyRules.isSafe(url: item.path) else {
                failures.append(DeletionFailure(
                    item: item,
                    reason: "Путь не разрешён правилами безопасности."
                ))
                continue
            }
            do {
                try fm.trashItem(at: item.path, resultingItemURL: nil)
            } catch {
                failures.append(DeletionFailure(item: item, reason: error.localizedDescription))
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
                let fm = FileManager.default
                for item in items {
                    if Task.isCancelled || cancellation.isCancelled { break }
                    guard SafetyRules.isSafe(url: item.path) else {
                        continuation.yield(.itemProcessed(
                            item: item,
                            failure: DeletionFailure(
                                item: item,
                                reason: "Путь не разрешён правилами безопасности."
                            )
                        ))
                        continue
                    }
                    do {
                        try fm.trashItem(at: item.path, resultingItemURL: nil)
                        continuation.yield(.itemProcessed(item: item, failure: nil))
                    } catch {
                        let failure = DeletionFailure(item: item, reason: error.localizedDescription)
                        continuation.yield(.itemProcessed(item: item, failure: failure))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
