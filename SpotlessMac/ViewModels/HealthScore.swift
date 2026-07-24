import SwiftUI

enum HealthBand {
    case excellent   // score >= 85
    case good        // 60-84
    case attention   // < 60

    var label: String {
        switch self {
        case .excellent: return "Отлично"
        case .good: return "Хорошо"
        case .attention: return "Требует внимания"
        }
    }

    var color: Color {
        switch self {
        case .excellent: return Theme.healthGreenText
        case .good: return Theme.accentGradientStart
        case .attention: return Theme.warningOrange
        }
    }
}

// Heuristic, not a scientific measurement: penalizes found junk size,
// low free disk space, and missing Full Disk Access. Tunable constants.
enum HealthScoreCalculator {
    static func compute(cleanableBytes: Int64, freeDiskFraction: Double, fdaStatus: FDAStatus) -> Int {
        let junkGB = Double(cleanableBytes) / 1_073_741_824
        let junkPenalty = min(50.0, junkGB * 2.5)                 // ~20 GB of junk => -50
        let diskPenalty: Double = freeDiskFraction < 0.10 ? 15 : (freeDiskFraction < 0.20 ? 5 : 0)
        let fdaPenalty: Double = fdaStatus == .denied ? 5 : 0
        let raw = 100.0 - junkPenalty - diskPenalty - fdaPenalty
        return max(0, min(100, Int(raw.rounded())))
    }

    static func band(for score: Int) -> HealthBand {
        if score >= 85 { return .excellent }
        if score >= 60 { return .good }
        return .attention
    }
}
