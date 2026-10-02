import Foundation

actor AppStorageService {
    typealias Measure = @Sendable (URL) async throws -> StorageMeasurement
    private let roots: [URL]
    private let measure: Measure
    private var entries: [URL]?
    private var indexComplete = true
    private let rootTrust: @Sendable (URL) -> Bool
    init(roots: [URL] = SafetyRules.uninstallLeftoverRoots,
         rootTrust: @escaping @Sendable (URL) -> Bool = SafetyRules.rootIsTrusted, measure: Measure? = nil) {
        self.roots = roots.filter(rootTrust)
        self.rootTrust = rootTrust
        self.indexComplete = self.roots.count == roots.count
        let readRoots = self.roots + SafetyRules.uninstallAppRoots.filter(rootTrust)
        let engine = StorageAnalysisEngine(policy: PathPolicy(readRoots: readRoots))
        self.measure = { url in
            guard readRoots.filter(rootTrust).contains(where: { PathPolicy.contains(PathPolicy.canonical(url), in: PathPolicy.canonical($0)) }) || measure != nil && url.pathExtension == "app" else {
                throw CocoaError(.fileReadNoPermission)
            }
            if let measure { return try await measure(url) }
            return try await engine.measure(url)
        }
    }
    static func supportAlias(bundleID: String?) -> String? {
        switch bundleID {
        case "com.todesktop.230313mzl4w4u92": "Cursor"
        case "com.anthropic.claudefordesktop": "Claude"
        case "com.wooffoow.Wooffoow": "wooffoow"
        default: nil
        }
    }
    private func inventory() -> [URL] {
        if let entries { return entries }
        var result: [URL] = []
        for root in roots where root.lastPathComponent != "Group Containers" {
            guard rootTrust(root) else { indexComplete = false; continue }
            do { result.append(contentsOf: try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) }
            catch { if FileManager.default.fileExists(atPath: root.path) { indexComplete = false } }
        }
        entries = result
        return result
    }
    func summary(for app: InstalledApp) async throws -> AppStorageSummary {
        try Task.checkCancellation()
        let inventory = inventory()
        var complete = indexComplete
        var bundleBytes: Int64 = 0
        do { let size = try await measure(app.bundleURL); bundleBytes = size.allocatedBytes; complete = complete && size.isComplete }
        catch { complete = false }
        var cachePaths: [URL] = []
        var dataPaths: [URL] = []
        if let bundleID = app.bundleID {
            for url in inventory {
                let rootName = url.deletingLastPathComponent().lastPathComponent
                let exact = LeftoverMatcher.isExact(component: url.lastPathComponent, bundleID: bundleID, rootName: rootName)
                let alias = rootName == "Application Support" && url.lastPathComponent == Self.supportAlias(bundleID: bundleID)
                guard (exact || alias), StorageFileIdentity.read(url)?.isSymbolicLink == false else { continue }
                if ["Caches", "Logs"].contains(rootName) { cachePaths.append(url) }
                else { dataPaths.append(url) }
                if alias {
                    cachePaths.append(contentsOf: KnownCacheScanner.locations(home: FileManager.default.homeDirectoryForCurrentUser).map(\.url).filter {
                        PathPolicy.contains(PathPolicy.canonical($0), in: PathPolicy.canonical(url), includeRoot: false) && StorageFileIdentity.read($0)?.isDirectory == true
                    })
                }
            }
        }
        var cacheBytes: Int64 = 0
        var dataBytes: Int64 = 0
        var nestedCacheBytes: Int64 = 0
        for path in Set(cachePaths) {
            try Task.checkCancellation()
            do {
                let size = try await measure(path); cacheBytes += size.allocatedBytes; complete = complete && size.isComplete
                if dataPaths.contains(where: { PathPolicy.contains(PathPolicy.canonical(path), in: PathPolicy.canonical($0), includeRoot: false) }) { nestedCacheBytes += size.allocatedBytes }
            } catch { complete = false }
        }
        for path in Set(dataPaths) {
            try Task.checkCancellation()
            do { let size = try await measure(path); dataBytes += size.allocatedBytes; complete = complete && size.isComplete }
            catch { complete = false }
        }
        return AppStorageSummary(appID: app.id, bundleBytes: bundleBytes, cacheBytes: cacheBytes, dataBytes: max(0, dataBytes - nestedCacheBytes), isComplete: complete)
    }
}
