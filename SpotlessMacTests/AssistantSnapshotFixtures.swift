import Foundation
@testable import SpotlessMac

extension SystemSnapshot {
    static let testHome = "/Users/tester"
    static let testDate = Date(timeIntervalSince1970: 1_790_000_000)

    static func sample() -> SystemSnapshot {
        func item(_ number: Int, _ path: String, _ gigabytes: Double, _ category: ScanCategory,
                  _ disposition: CleanupDisposition, daysOld: Int?) -> SnapshotItem {
            SnapshotItem(
                shortID: "c\(number)", itemID: UUID(), path: testHome + path,
                bytes: Int64(gigabytes * 1_000_000_000), category: category, disposition: disposition,
                reason: category.cleanupReason,
                modifiedAt: daysOld.map { testDate.addingTimeInterval(-Double($0) * 86_400) }, owner: nil
            )
        }
        let items = [
            item(1, "/Library/Developer/Xcode/DerivedData", 9.8, .developerCaches, .rebuildable, daysOld: 50),
            item(2, "/Projects/secret-client/node_modules", 3.2, .projectArtifacts, .rebuildable, daysOld: 90),
            item(3, "/Library/Caches/com.spotify.client", 1.5, .userCaches, .rebuildable, daysOld: 2),
            item(4, "/Documents/Мой проект/recording.m4a", 0.9, .recordings, .personalData, daysOld: 10),
            item(5, "/Library/Logs/DiagnosticReports", 0.4, .logs, .rebuildable, daysOld: 40),
            item(6, "/Downloads/big.iso", 0.3, .largeFiles, .inspectOnly, daysOld: 200),
        ]
        let categories = Dictionary(grouping: items, by: \.category)
            .map { CategorySummary(category: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }, count: $0.value.count) }
            .sorted { $0.bytes > $1.bytes }
        return SystemSnapshot(
            takenAt: testDate,
            volume: VolumeInfo(name: "Macintosh HD", totalBytes: 494_000_000_000, availableBytes: 31_000_000_000),
            fullDiskAccess: true,
            lastScanAt: testDate.addingTimeInterval(-3_600),
            categories: categories,
            items: items,
            docker: DockerInfo(status: "Docker запущен", virtualDiskBytes: 48_000_000_000, reclaimableBytes: 6_000_000_000,
                               kinds: [DockerKindSummary(kindName: "Неиспользуемые образы", count: 12, bytes: 5_000_000_000, dataLossCount: 0)]),
            leftovers: nil,
            lastCleanup: nil,
            memory: MemoryInfo(load: .normal, usedBytes: 12_000_000_000, physicalBytes: 16_000_000_000, swapUsedBytes: 0,
                               topApps: [MemoryAppInfo(name: "Xcode", bytes: 4_000_000_000), MemoryAppInfo(name: "Google Chrome", bytes: 2_500_000_000)])
        )
    }
}
