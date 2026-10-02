import AppKit
import Foundation
import Observation

struct MemoryHistoryPoint: Sendable, Equatable, Identifiable {
    let date: Date
    let swapUsed: UInt64
    let compressed: UInt64
    let pressure: MemoryPressure
    var id: Date { date }
}

/// Quits applications through `NSRunningApplication` only — never `kill(2)`.
struct AppTerminator: Sendable {
    var terminate: @MainActor @Sendable ([pid_t]) -> Void
    var forceTerminate: @MainActor @Sendable ([pid_t]) -> Void
    var isAnyRunning: @MainActor @Sendable ([pid_t]) -> Bool

    static let live = AppTerminator(
        terminate: { pids in pids.forEach { _ = NSRunningApplication(processIdentifier: $0)?.terminate() } },
        forceTerminate: { pids in pids.forEach { _ = NSRunningApplication(processIdentifier: $0)?.forceTerminate() } },
        isAnyRunning: { pids in
            pids.contains { NSRunningApplication(processIdentifier: $0).map { !$0.isTerminated } ?? false }
        }
    )
}

enum QuitState: Equatable {
    case idle
    case confirm(AppMemoryGroup, QuitDecision)
    case quitting(AppMemoryGroup)
    case stillRunning(AppMemoryGroup)
    case finished(String)
}

@Observable @MainActor
final class MemoryViewModel {
    typealias Sample = @Sendable () async -> MemorySample

    static let historyLimit = 150
    static let resortInterval: TimeInterval = 10

    private(set) var latest: MemorySample?
    private(set) var history: [MemoryHistoryPoint] = []
    /// Groups in display order; re-sorted at most every `resortInterval`.
    private(set) var displayedGroups: [AppMemoryGroup] = []
    var expandedGroupIDs: Set<String> = []
    private(set) var quitState: QuitState = .idle

    private let sample: Sample
    private let terminator: AppTerminator
    private let interval: Duration
    private let quitGracePeriod: Duration
    private let ownBundlePath: String
    private var loop: Task<Void, Never>?
    private var lastSort: Date?

    init(
        sample: Sample? = nil,
        terminator: AppTerminator = .live,
        interval: Duration = .seconds(2),
        quitGracePeriod: Duration = .seconds(5),
        ownBundlePath: String = Bundle.main.bundlePath
    ) {
        let monitor = MemoryMonitor()
        self.sample = sample ?? { await monitor.sample() }
        self.terminator = terminator
        self.interval = interval
        self.quitGracePeriod = quitGracePeriod
        self.ownBundlePath = ownBundlePath
    }

    var isRunning: Bool { loop != nil }

    func start() {
        loop?.cancel()
        let sample = sample
        let interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let next = await sample()
                guard !Task.isCancelled else { return }
                self?.apply(next)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func resortNow() {
        guard let latest else { return }
        displayedGroups = Self.order(latest.groups, previous: displayedGroups, resort: true)
        lastSort = latest.date
    }

    func apply(_ next: MemorySample) {
        latest = next
        history.append(MemoryHistoryPoint(date: next.date, swapUsed: next.system.swapUsed,
                                          compressed: next.system.compressed, pressure: next.system.pressure))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        let resort = lastSort.map { next.date.timeIntervalSince($0) >= Self.resortInterval } ?? true
        displayedGroups = Self.order(next.groups, previous: displayedGroups, resort: resort)
        if resort { lastSort = next.date }
    }

    /// Keeps the previous order for known groups (so expanded rows don't jump),
    /// appends new ones, drops vanished ones. `resort` uses the fresh order.
    static func order(_ groups: [AppMemoryGroup], previous: [AppMemoryGroup], resort: Bool) -> [AppMemoryGroup] {
        if resort || previous.isEmpty { return groups }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = previous.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + groups.filter { !keptIDs.contains($0.id) }
    }

    // MARK: Quit flow

    func requestQuit(_ group: AppMemoryGroup) {
        let apps = latest?.runningApps(in: group) ?? []
        let decision = ProcessSafetyRules.canQuit(
            group, runningApps: apps, currentUID: getuid(),
            ownBundlePath: ownBundlePath, ownPID: getpid()
        )
        quitState = .confirm(group, decision)
    }

    func confirmQuit() async {
        guard case .confirm(let group, .allowed) = quitState else { return }
        let pids = (latest?.runningApps(in: group) ?? []).map(\.pid)
        quitState = .quitting(group)
        terminator.terminate(pids)

        let step = Duration.milliseconds(250)
        var waited = Duration.zero
        while waited < quitGracePeriod {
            if !terminator.isAnyRunning(pids) {
                quitState = .finished("\(group.displayName) завершено.")
                return
            }
            try? await Task.sleep(for: step)
            waited += step
        }
        quitState = terminator.isAnyRunning(pids) ? .stillRunning(group) : .finished("\(group.displayName) завершено.")
    }

    func confirmForceQuit() {
        guard case .stillRunning(let group) = quitState else { return }
        let pids = (latest?.runningApps(in: group) ?? []).map(\.pid)
        terminator.forceTerminate(pids)
        quitState = .finished("\(group.displayName) завершено принудительно.")
    }

    func dismissQuit() {
        quitState = .idle
    }
}
