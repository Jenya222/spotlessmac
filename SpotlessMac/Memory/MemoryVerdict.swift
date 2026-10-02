import Foundation

/// One rule-generated sentence summarizing memory state.
enum MemoryVerdict {
    static func text(system: SystemMemorySnapshot, groups: [AppMemoryGroup]) -> String {
        let top = groups.filter { $0.kind == .userApp }.prefix(2)
            .map { "\($0.displayName) (\(format($0.footprint)))" }
            .joined(separator: ", ")
        let holders = top.isEmpty ? "" : " Больше всего держат: \(top)."
        let heavySwap = system.physical > 0 && system.swapUsed * 4 > system.physical

        if system.pressure == .critical || heavySwap {
            // Critical pressure can occur before anything reached swap; don't report "Своп 0 KB".
            if system.swapUsed == 0 {
                return "Память на пределе — система сжимает данные.\(holders)"
            }
            return "Своп \(format(system.swapUsed)) — система активно вытесняет память.\(holders)"
        }
        if system.pressure == .warning {
            return "Память под нагрузкой.\(holders)"
        }
        return "Памяти достаточно."
    }

    /// Created per call: `ByteCountFormatter` is not `Sendable`, so a shared static
    /// instance would not pass Swift 6 strict concurrency.
    static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        // Without this, 0 bytes renders as the English "Zero KB".
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
