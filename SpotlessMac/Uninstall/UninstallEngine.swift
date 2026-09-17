import Foundation

struct UninstallFailure: Sendable {
    let item: LeftoverItem
    let reason: String
}

actor UninstallEngine {
    private let leftoverRoots: [URL]

    init(leftoverRoots: [URL] = SafetyRules.uninstallLeftoverRoots) {
        self.leftoverRoots = leftoverRoots
    }

    // Lists actionable apps in /Applications and ~/Applications.
    // Apple/system apps (com.apple.*) are excluded; /System/Applications is
    // never enumerated.
    func listApps() async -> [InstalledApp] {
        var result: [InstalledApp] = []
        for root in SafetyRules.uninstallAppRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "app" {
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
            let label = root.lastPathComponent
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let comp = url.lastPathComponent
                if let bundleID,
                   LeftoverMatcher.isExact(component: comp, bundleID: bundleID, rootName: label) {
                    exactURLs.append((url, label))
                } else if (bundleID.map { LeftoverMatcher.isRelatedCandidate(component: comp, bundleID: $0) } ?? false)
                            || Self.matchesName(comp, displayName: displayName, fileName: bundleFileName) {
                    nameURLs.append((url, label))
                }
            }
        }

        // Size everything in parallel off the main actor.
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
                                        confidence: .exact, isSelected: true)
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
        let fm = FileManager.default
        for item in items {
            guard SafetyRules.isSafeToUninstall(url: item.path) else {
                failures.append(UninstallFailure(
                    item: item,
                    reason: "Путь не разрешён правилами безопасности."
                ))
                continue
            }
            do {
                try fm.trashItem(at: item.path, resultingItemURL: nil)
            } catch {
                failures.append(UninstallFailure(item: item, reason: error.localizedDescription))
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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let rv = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv?.isRegularFile == true {
                total += Int64(rv?.fileSize ?? 0)
            }
        }
        return total
    }
}
