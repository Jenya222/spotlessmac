import Foundation

struct UninstallFailure: Sendable {
    let item: LeftoverItem
    let reason: String
}

actor UninstallEngine {
    private let leftoverRoots: [URL]
    private let cacheLocations: [KnownCacheLocation]
    private let activity: @Sendable (ScanItem) async -> OwnerActivity
    private let validate: @Sendable (LeftoverItem) -> String?
    private let trash: @Sendable (URL) throws -> Void

    init(leftoverRoots: [URL] = SafetyRules.uninstallLeftoverRoots,
         cacheLocations: [KnownCacheLocation] = KnownCacheScanner.locations(home: FileManager.default.homeDirectoryForCurrentUser),
         activity: @escaping @Sendable (ScanItem) async -> OwnerActivity = OwnerActivityChecker.check,
         validate: @escaping @Sendable (LeftoverItem) -> String? = UninstallEngine.validationFailure,
         trash: @escaping @Sendable (URL) throws -> Void = {
             guard SafetyRules.isSafeToUninstall(url: $0) else { throw CocoaError(.fileWriteNoPermission) }
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         }) {
        self.leftoverRoots = leftoverRoots
        self.cacheLocations = cacheLocations
        self.activity = activity; self.validate = validate; self.trash = trash
    }
    private nonisolated static func validationFailure(_ item: LeftoverItem) -> String? {
        guard SafetyRules.isSafeToUninstall(url: item.path), let current = StorageFileIdentity.read(item.path),
              !current.isSymbolicLink, current.isDirectory || current.isRegularFile, item.identity == current else {
            return "Путь или объект изменился после предпросмотра. Сканируйте снова."
        }
        return nil
    }

    // Lists actionable apps in /Applications and ~/Applications.
    // Apple/system apps (com.apple.*) are excluded; /System/Applications is
    // never enumerated.
    func listApps() async -> [InstalledApp] {
        var result: [InstalledApp] = []
        for root in SafetyRules.uninstallAppRoots where SafetyRules.rootIsTrusted(root) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "app" {
                guard StorageFileIdentity.read(url)?.isDirectory == true else { continue }
                let info = Self.readInfoPlist(appURL: url)
                let bundleID = info?["CFBundleIdentifier"] as? String
                if let bundleID, bundleID.hasPrefix("com.apple.") { continue }
                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                result.append(InstalledApp(name: name, bundleURL: url, bundleID: bundleID))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Finds the .app itself plus leftover files across the Library roots.
    func findLeftovers(for app: InstalledApp) async -> [LeftoverItem] {
        let bundleID = app.bundleID
        let displayName = app.name
        let bundleFileName = app.bundleURL.deletingPathExtension().lastPathComponent

        // Discover candidate URLs (cheap, no sizing yet).
        var exactURLs: [(URL, String)] = []   // (url, location label)
        var nameURLs: [(URL, String)] = []

        for root in leftoverRoots {
            if SafetyRules.uninstallLeftoverRoots.contains(root) && !SafetyRules.rootIsTrusted(root) { continue }
            let label = root.lastPathComponent
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let comp = url.lastPathComponent
                if let bundleID,
                   (LeftoverMatcher.isExact(component: comp, bundleID: bundleID, rootName: label) || (label == "Application Support" && comp == AppStorageService.supportAlias(bundleID: bundleID))) {
                    exactURLs.append((url, label))
                } else if (bundleID.map { LeftoverMatcher.isRelatedCandidate(component: comp, bundleID: $0) } ?? false)
                            || Self.matchesName(comp, displayName: displayName, fileName: bundleFileName) {
                    nameURLs.append((url, label))
                }
            }
        }

        if let alias = AppStorageService.supportAlias(bundleID: bundleID) {
            for cache in KnownCacheScanner.locations(home: FileManager.default.homeDirectoryForCurrentUser) where cache.owner == alias || cache.owner.lowercased() == alias.lowercased() {
                if SafetyRules.rootIsTrusted(cache.url), StorageFileIdentity.read(cache.url)?.isDirectory == true { exactURLs.append((cache.url, "Кэш приложения")) }
            }
        }
        // Size confirmed roots without preselecting personal data.
        let appURL = app.bundleURL
        let exactInputs = exactURLs
        let nameInputs = nameURLs

        var items: [LeftoverItem] = []
        await withTaskGroup(of: LeftoverItem?.self) { group in
            // The .app bundle itself — always exact, selected.
            group.addTask(priority: .utility) {
                let size = Self.recursiveSize(appURL)
                return LeftoverItem(path: appURL, size: size, location: "Программа",
                                    confidence: .exact, isSelected: true)
            }
            for (url, label) in exactInputs {
                group.addTask(priority: .utility) {
                    let size = Self.recursiveSize(url)
                    return LeftoverItem(path: url, size: size, location: label,
                                        confidence: .exact, isSelected: ["Caches", "Logs"].contains(label))
                }
            }
            for (url, label) in nameInputs {
                group.addTask(priority: .utility) {
                    let size = Self.recursiveSize(url)
                    return LeftoverItem(path: url, size: size, location: label,
                                        confidence: .nameOnly, isSelected: false)
                }
            }
            for await item in group {
                if let item { items.append(item) }
            }
        }

        // Exact first (largest first), then name-only (largest first).
        let exact = items.filter { $0.confidence == .exact }.sorted { $0.size > $1.size }
        let nameOnly = items.filter { $0.confidence == .nameOnly }.sorted { $0.size > $1.size }
        return exact + nameOnly
    }

    // Trash-only deletion. Every item is gated through isSafeToUninstall.
    func uninstall(items: [LeftoverItem]) async -> [UninstallFailure] {
        var failures: [UninstallFailure] = []
        for item in LeftoverItem.nonOverlapping(items) {
            if let reason = validate(item) {
                failures.append(UninstallFailure(item: item, reason: reason)); continue
            }
            // A containing personal-data directory can also include a catalogued cache.
            let affected = cacheLocations.filter {
                PathPolicy.contains(PathPolicy.canonical($0.url), in: PathPolicy.canonical(item.path))
                    || PathPolicy.contains(PathPolicy.canonical(item.path), in: PathPolicy.canonical($0.url))
            }
            var ownerFailure: String?
            for cache in affected {
                let candidate = ScanItem(path: cache.url, size: 0, category: .knownAppCaches,
                    cleanupPolicy: .init(disposition: .rebuildable, reason: "Кэш приложения", requiresClosedOwner: true), owner: cache.owner)
                if await activity(candidate) != .closed {
                    ownerFailure = "Закройте приложение. Не удалось подтвердить, что кэш не используется."; break
                }
            }
            if let reason = ownerFailure ?? validate(item) {
                failures.append(UninstallFailure(item: item, reason: reason)); continue
            }
            do { try trash(item.path) }
            catch { failures.append(UninstallFailure(item: item, reason: error.localizedDescription)) }
        }
        let failedTargets = failures
        for item in items where !failures.contains(where: { $0.item.id == item.id }) {
            if let parentFailure = failedTargets.first(where: { PathPolicy.contains(PathPolicy.canonical(item.path), in: PathPolicy.canonical($0.item.path)) }) {
                failures.append(UninstallFailure(item: item, reason: parentFailure.reason))
            }
        }
        return failures
    }

    // MARK: - Matching

    private static func matchesName(_ component: String, displayName: String, fileName: String) -> Bool {
        let stem = (component as NSString).deletingPathExtension
        return stem.compare(displayName, options: .caseInsensitive) == .orderedSame
            || stem.compare(fileName, options: .caseInsensitive) == .orderedSame
    }

    // MARK: - Helpers

    private static func readInfoPlist(appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    private nonisolated static func recursiveSize(_ url: URL) -> Int64 {
        (try? StorageAnalysisEngine.measureNow(url, policy: PathPolicy(readRoots: [url])).allocatedBytes) ?? 0
    }
}
