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
            return "Своп \(format(system.swapUsed)) — система активно вытесняет память.\(holders)"
        }
        if system.pressure == .warning {
            return "Память под нагрузкой.\(holders)"
        }
        return "Памяти достаточно."
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
