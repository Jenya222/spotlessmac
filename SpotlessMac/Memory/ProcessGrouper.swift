import Darwin
import Foundation

/// Collapses processes into the application responsible for them.
enum ProcessGrouper {
    static let systemGroupID = "system"
    private static let maxParentDepth = 32

    /// `/Applications/Google Chrome.app` → `Google Chrome`. String-based on purpose:
    /// `URL(fileURLWithPath:)` stats the filesystem, and this runs on every sample.
    private static func displayName(forBundle path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func group(
        _ processes: [ProcessMemorySample],
        runningApps: [RunningAppInfo],
        currentUID: uid_t
    ) -> [AppMemoryGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let appByPID = Dictionary(runningApps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let regularBundles = Set(runningApps.filter { $0.policy == .regular }.map(\.bundlePath))

        func bundle(of pid: pid_t) -> String? {
            if let app = appByPID[pid] { return app.bundlePath }
            return byPID[pid]?.path.flatMap(BundlePath.outermostApp(in:))
        }

        func resolveBundle(for process: ProcessMemorySample) -> String? {
            if let responsible = process.responsiblePID, responsible != process.pid,
               let path = bundle(of: responsible) {
                return path
            }
            var current: pid_t? = process.pid
            var visited = Set<pid_t>()
            while let pid = current, pid > 1, visited.count < maxParentDepth, visited.insert(pid).inserted {
                if let path = bundle(of: pid) { return path }
                current = byPID[pid]?.ppid
            }
            return nil
        }

        var userApps: [String: [ProcessMemorySample]] = [:]
        var others: [String: [ProcessMemorySample]] = [:]
        var system: [ProcessMemorySample] = []

        for process in processes {
            let path = resolveBundle(for: process)
            if let path, regularBundles.contains(path) || !BundlePath.isSystem(path) {
                userApps[path, default: []].append(process)
            } else if path != nil || process.uid != currentUID || process.path.map(BundlePath.isSystem) == true {
                system.append(process)
            } else {
                others[process.name, default: []].append(process)
            }
        }

        func sorted(_ list: [ProcessMemorySample]) -> [ProcessMemorySample] {
            list.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.pid < $1.pid }
        }

        var groups = userApps.map { path, list in
            AppMemoryGroup(
                id: path,
                displayName: displayName(forBundle: path),
                kind: .userApp, bundlePath: path, processes: sorted(list)
            )
        }
        groups += others.map { name, list in
            AppMemoryGroup(id: "other:" + name, displayName: name, kind: .other, bundlePath: nil, processes: sorted(list))
        }
        if !system.isEmpty {
            groups.append(AppMemoryGroup(id: systemGroupID, displayName: "Система", kind: .system,
                                         bundlePath: nil, processes: sorted(system)))
        }
        return groups.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }
}
