import Foundation

struct CategoryTotal: Identifiable, Sendable {
    let category: ScanCategory
    let totalBytes: Int64
    var id: String { category.rawValue }
}

struct SmartCareRun: Identifiable, Sendable {
    let id: UUID
    let items: [ScanItem]
    let totalBytes: Int64
    let categoryTotals: [CategoryTotal]

    init(id: UUID = UUID(), items: [ScanItem]) {
        self.id = id
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.size }
        let grouped = Dictionary(grouping: items, by: \.category)
        self.categoryTotals = grouped
            .map { CategoryTotal(category: $0.key, totalBytes: $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }
}

enum SmartCareOutcome: Equatable, Sendable {
    case succeeded
    case partialFailure
    case failed
    case cancelled

    static func classify(
        successfulCount: Int,
        failedCount: Int,
        unprocessedCount: Int,
        cancellationRequested: Bool
    ) -> SmartCareOutcome {
        if cancellationRequested, unprocessedCount > 0 {
            return .cancelled
        }
        if failedCount == 0, unprocessedCount == 0, successfulCount > 0 {
            return .succeeded
        }
        if successfulCount > 0 {
            return .partialFailure
        }
        return .failed
    }

    var displayTitle: String {
        switch self {
        case .succeeded: "Очистка завершена"
        case .partialFailure: "Очистка завершена с ошибками"
        case .failed: "Не удалось выполнить очистку"
        case .cancelled: "Очистка остановлена"
        }
    }
}

enum SmartCareCategoryState: Equatable, Sendable {
    case pending
    case cleaning
    case succeeded
    case failed
    case cancelled

    static func resolve(
        isRunning: Bool,
        isCurrent: Bool,
        itemCount: Int,
        successfulCount: Int,
        failedCount: Int,
        unprocessedCount: Int,
        outcome: SmartCareOutcome?
    ) -> SmartCareCategoryState {
        if isRunning, isCurrent { return .cleaning }
        if itemCount > 0, successfulCount == itemCount { return .succeeded }
        if failedCount > 0 { return .failed }
        if outcome == .cancelled, unprocessedCount > 0 { return .cancelled }
        if !isRunning, outcome != nil, unprocessedCount > 0 { return .failed }
        return .pending
    }
}

final class CleaningCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
