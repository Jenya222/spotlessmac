import Darwin
import Foundation
@testable import SpotlessMac

enum MemoryFixtures {
    static let me: uid_t = 501

    static func process(
        _ pid: pid_t, ppid: pid_t = 1, uid: uid_t? = 501, name: String = "proc",
        path: String? = nil, responsible: pid_t? = nil,
        footprint: UInt64 = 100, resident: UInt64 = 100, partial: Bool = false
    ) -> ProcessMemorySample {
        ProcessMemorySample(pid: pid, ppid: ppid, uid: uid, name: name, path: path, responsiblePID: responsible,
                            footprint: footprint, resident: resident, isPartial: partial)
    }

    static func app(
        _ pid: pid_t, _ bundlePath: String, id: String? = nil,
        policy: RunningAppInfo.ActivationPolicy = .regular
    ) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundlePath: bundlePath, bundleIdentifier: id, policy: policy)
    }

    static func userGroup(_ bundlePath: String, processes: [ProcessMemorySample]) -> AppMemoryGroup {
        AppMemoryGroup(id: bundlePath, displayName: URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent,
                       kind: .userApp, bundlePath: bundlePath, processes: processes)
    }

    static func system(
        physical: UInt64 = 16 << 30, compressed: UInt64 = 0, swapUsed: UInt64 = 0,
        pressure: MemoryPressure = .normal
    ) -> SystemMemorySnapshot {
        SystemMemorySnapshot(physical: physical, appMemory: 4 << 30, wired: 2 << 30, compressed: compressed,
                             cachedFiles: 1 << 30, free: 1 << 30, swapUsed: swapUsed, swapTotal: 20 << 30,
                             pressure: pressure)
    }

    static func sample(
        at date: Date, groups: [AppMemoryGroup] = [], runningApps: [RunningAppInfo] = [],
        swapUsed: UInt64 = 0
    ) -> MemorySample {
        MemorySample(date: date, system: system(swapUsed: swapUsed), groups: groups, runningApps: runningApps)
    }
}
