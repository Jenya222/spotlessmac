import Foundation

struct VolumeSample: Sendable, Equatable {
    let volumeID: String
    let availableBytes: Int64
    let sampledAt: Date
}

struct CleanupReport: Sendable, Equatable {
    let trashedBytes: Int64
    let successfulItems: Int
    let before: VolumeSample?
    let after: VolumeSample?
    var observedFreeSpaceDelta: Int64? {
        guard let before, let after, before.volumeID == after.volumeID else { return nil }
        return after.availableBytes - before.availableBytes
    }
    var measurementPeriodDescription: String? {
        guard let before, let after, before.volumeID == after.volumeID else { return nil }
        return "Измерено: " + before.sampledAt.formatted(date: .abbreviated, time: .standard)
            + " — " + after.sampledAt.formatted(date: .abbreviated, time: .standard)
    }
    var measurementDescription: String {
        [freeSpaceDescription, measurementPeriodDescription].compactMap { $0 }.joined(separator: ". ")
    }
    var freeSpaceDescription: String {
        guard let delta = observedFreeSpaceDelta else { return "Изменение свободного места не измерено" }
        let amount = ByteCountFormatter.string(fromByteCount: abs(delta), countStyle: .file)
        return delta >= 0 ? "Свободного места стало больше на \(amount)" : "Свободного места стало меньше на \(amount)"
    }
}
