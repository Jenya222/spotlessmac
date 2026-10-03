import AppKit
import Darwin

/// Wraps the private `responsibility_get_pid_responsible_for_pid`, which
/// Activity Monitor uses to attribute XPC services and VMs to their app.
/// Missing symbol → every lookup returns nil and attribution falls back
/// to bundle paths and the parent chain.
struct ResponsibilityResolver: @unchecked Sendable {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    private let function: Function?

    static let live = ResponsibilityResolver()

    private init() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        function = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Function.self) }
    }

    func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}

enum ProcessMemoryReader {
    static func readAll(responsibility: ResponsibilityResolver = .live) -> [ProcessMemorySample] {
        listPIDs().compactMap { read(pid: $0, responsibility: responsibility) }
    }

    private static func listPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return pids.prefix(Int(max(count, 0))).filter { $0 > 0 }
    }

    private static func read(pid: pid_t, responsibility: ResponsibilityResolver) -> ProcessMemorySample? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

        let path = string(capacity: Int(MAXPATHLEN) * 4) { proc_pidpath(pid, $0, $1) }
        let arguments = arguments(pid: pid)
        let name = argumentZero(arguments)
            ?? string(capacity: 256) { proc_name(pid, $0, $1) }
            ?? path.map { ($0 as NSString).lastPathComponent }
        guard hasBSD || path != nil || name != nil else { return nil } // process exited

        var usage = rusage_info_v4()
        let rusageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let hasUsage = rusageResult == 0

        return ProcessMemorySample(
            pid: pid,
            ppid: hasBSD ? pid_t(bsd.pbi_ppid) : 0,
            uid: hasBSD ? bsd.pbi_uid : nil,
            name: name ?? "pid \(pid)",
            path: path,
            responsiblePID: responsibility.responsiblePID(for: pid),
            footprint: hasUsage ? usage.ri_phys_footprint : 0,
            resident: hasUsage ? usage.ri_resident_size : 0,
            isPartial: !hasUsage,
            role: arguments.flatMap(HelperRole.classify)
        )
    }

    /// The process's argv. Only readable for the current user's processes.
    private static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Array(buffer.prefix(size)))
    }

    /// Last path component of argv[0] — `claude` rather than the versioned
    /// binary name `2.1.285`.
    private static func argumentZero(_ arguments: [String]?) -> String? {
        guard let first = arguments?.first, !first.isEmpty else { return nil }
        // NSString, not URL: `URL(fileURLWithPath:)` stats the filesystem, and this runs per process.
        let name = (first as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func string(
        capacity: Int, _ fill: (UnsafeMutableRawPointer, UInt32) -> Int32
    ) -> String? {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBytes { fill($0.baseAddress!, UInt32(capacity)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

enum RunningAppsReader {
    private static func policy(_ policy: NSApplication.ActivationPolicy) -> RunningAppInfo.ActivationPolicy {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        default: return .prohibited
        }
    }

    static func current() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL,
                  let bundlePath = BundlePath.outermostApp(in: url.path) else { return nil }
            return RunningAppInfo(
                pid: app.processIdentifier,
                bundlePath: bundlePath,
                bundleIdentifier: app.bundleIdentifier,
                policy: policy(app.activationPolicy)
            )
        }
    }
}
