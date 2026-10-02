import Darwin
import Foundation

/// Page counts from `host_statistics64(HOST_VM_INFO64)`.
struct VMPageCounts: Sendable, Equatable {
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var internalPages: UInt64 = 0
    var externalPages: UInt64 = 0
    var purgeable: UInt64 = 0
    var compressor: UInt64 = 0
}

enum SystemMemoryReader {
    static func current() -> SystemMemorySnapshot {
        let swap = readSwap()
        return snapshot(
            pages: readPages() ?? VMPageCounts(),
            pageSize: UInt64(getpagesize()),
            physical: ProcessInfo.processInfo.physicalMemory,
            swapUsed: swap.used, swapTotal: swap.total,
            pressureLevel: readPressureLevel()
        )
    }

    /// Same breakdown as Activity Monitor: app = internal − purgeable,
    /// cached files = external + purgeable.
    static func snapshot(
        pages: VMPageCounts, pageSize: UInt64, physical: UInt64,
        swapUsed: UInt64, swapTotal: UInt64, pressureLevel: Int32?
    ) -> SystemMemorySnapshot {
        let internalPages = pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0
        return SystemMemorySnapshot(
            physical: physical,
            appMemory: internalPages * pageSize,
            wired: pages.wired * pageSize,
            compressed: pages.compressor * pageSize,
            cachedFiles: (pages.externalPages + pages.purgeable) * pageSize,
            free: pages.free * pageSize,
            swapUsed: swapUsed, swapTotal: swapTotal,
            pressure: MemoryPressure(sysctlLevel: pressureLevel)
        )
    }

    private static func readPages() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            free: UInt64(stats.free_count),
            wired: UInt64(stats.wire_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            purgeable: UInt64(stats.purgeable_count),
            compressor: UInt64(stats.compressor_page_count)
        )
    }

    private static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func readPressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level
    }
}
