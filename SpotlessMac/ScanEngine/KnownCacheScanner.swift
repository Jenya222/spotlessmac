import Foundation

struct KnownCacheLocation: Sendable {
    let url: URL
    let owner: String
}
struct KnownCacheScanner: Scanner {
    let category: ScanCategory = .knownAppCaches
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    static func locations(home: URL) -> [KnownCacheLocation] {
        let paths: [(String, String)] = [
            ("Library/Application Support/Cursor/Cache", "Cursor"),
            ("Library/Application Support/Cursor/Code Cache", "Cursor"),
            ("Library/Application Support/Cursor/CachedData", "Cursor"),
            ("Library/Application Support/Cursor/CachedExtensionVSIXs", "Cursor"),
            ("Library/Application Support/Claude/Cache", "Claude"),
            ("Library/Application Support/Claude/Code Cache", "Claude"),
            (".cache/uv", "uv / Python"), (".npm/_cacache", "npm / Node.js")
        ]
        return paths.map { KnownCacheLocation(url: home.appending(path: $0.0), owner: $0.1) }
    }
    func scan() async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for location in Self.locations(home: home) {
            try Task.checkCancellation()
            guard PathPolicy.isUnredirected(location.url, below: home), let identity = StorageFileIdentity.read(location.url), identity.isDirectory else { continue }
            let size = try await StorageAnalysisEngine(policy: PathPolicy(readRoots: [location.url])).measure(location.url)
            guard size.isComplete, size.allocatedBytes > 0 else { continue }
            items.append(ScanItem(path: location.url, size: size.allocatedBytes, category: category, isSelected: false,
                cleanupPolicy: CleanupPolicy(disposition: .rebuildable, reason: "Кэш \(location.owner). Закройте программу или инструмент перед очисткой.", requiresClosedOwner: true), owner: location.owner))
        }
        return items.sorted { $0.size > $1.size }
    }
}
