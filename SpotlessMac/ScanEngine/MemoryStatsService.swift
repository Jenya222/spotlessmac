import Darwin
import Foundation

struct MemoryStats: Sendable {
    let freeBytes: Int64
    let totalBytes: Int64
    var freeFraction: Double { totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0 }
    var formattedFree: String { ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .memory) }
}

enum MemoryStatsService {
    // "Free" here means free + inactive pages — the common approximation
    // of "available" memory macOS itself uses in Activity Monitor.
    static func current() -> MemoryStats {
        let totalBytes = Int64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryStats(freeBytes: 0, totalBytes: totalBytes)
        }
        let pageSize = Int64(getpagesize())
        let freePages = Int64(stats.free_count) + Int64(stats.inactive_count)
        return MemoryStats(freeBytes: freePages * pageSize, totalBytes: totalBytes)
    }
}
