import Darwin
import Foundation

enum MemoryPressure: Int, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    init(sysctlLevel: Int32?) {
        self = sysctlLevel.flatMap { MemoryPressure(rawValue: Int($0)) } ?? .unknown
    }
}

struct SystemMemorySnapshot: Sendable, Equatable {
    var physical: UInt64
    var appMemory: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cachedFiles: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure

    /// Matches Activity Monitor's "Memory Used".
    var used: UInt64 { appMemory + wired + compressed }
}

struct ProcessMemorySample: Sendable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t?
    let name: String
    let path: String?
    let responsiblePID: pid_t?
    let footprint: UInt64
    let resident: UInt64
    /// True when the memory figures could not be read (other users, root).
    let isPartial: Bool
    /// Chromium/Electron helper role from the command line; nil for other processes.
    var role: HelperRole? = nil

    /// Estimate of the part held compressed or in swap.
    var pushedOut: UInt64 { footprint > resident ? footprint - resident : 0 }
}

struct RunningAppInfo: Sendable, Equatable {
    let pid: pid_t
    /// Outermost `*.app` that contains the application bundle.
    let bundlePath: String
    let bundleIdentifier: String?
    let policy: ActivationPolicy

    enum ActivationPolicy: Sendable, Equatable { case regular, accessory, prohibited }
}

struct AppMemoryGroup: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case userApp, system, other }

    let id: String
    let displayName: String
    let kind: Kind
    /// Outermost bundle path for `.userApp` groups.
    let bundlePath: String?
    /// Processes sorted by footprint, largest first.
    let processes: [ProcessMemorySample]

    var footprint: UInt64 { processes.reduce(0) { $0 + $1.footprint } }
    var pushedOut: UInt64 { processes.reduce(0) { $0 + $1.pushedOut } }
    var hasPartialData: Bool { processes.contains { $0.isPartial } }
}

struct MemorySample: Sendable, Equatable {
    let date: Date
    let system: SystemMemorySnapshot
    let groups: [AppMemoryGroup]
    let runningApps: [RunningAppInfo]

    func runningApps(in group: AppMemoryGroup) -> [RunningAppInfo] {
        guard let path = group.bundlePath else { return [] }
        return runningApps.filter { $0.bundlePath == path }
    }
}

enum BundlePath {
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// `/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/...` → `/Applications/Docker.app`.
    static func outermostApp(in path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(String(component))
            if component.hasSuffix(".app") { return "/" + components.joined(separator: "/") }
        }
        return nil
    }

    static func isSystem(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }
}
