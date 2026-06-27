import Foundation

enum SafetyRules {
    static let allowedRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Caches",   directoryHint: .isDirectory),
            home.appending(path: "Library/Logs",      directoryHint: .isDirectory),
            home.appending(path: "Downloads",         directoryHint: .isDirectory),
            home.appending(path: "Movies",            directoryHint: .isDirectory),
            home.appending(path: "Documents",         directoryHint: .isDirectory),
            home.appending(path: "Desktop",           directoryHint: .isDirectory),
            home.appending(path: "Music",             directoryHint: .isDirectory),
            home.appending(path: "Pictures",          directoryHint: .isDirectory),
            URL(filePath: "/Library/Caches", directoryHint: .isDirectory),
            URL(filePath: "/Library/Logs",   directoryHint: .isDirectory),
        ]
    }()

    static let forbiddenPrefixes: [String] = [
        "/System",
        "/private/var/vm",
        "/dev",
        "/cores",
    ]

    static func isSafe(url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        guard allowedRoots.contains(where: { path.hasPrefix($0.path(percentEncoded: false)) }) else {
            return false
        }
        return !forbiddenPrefixes.contains(where: { path.hasPrefix($0) })
    }

    // MARK: - Uninstall whitelist (separate from the cleaner's whitelist)

    // Roots where actionable .app bundles live. Never /System/Applications.
    static let uninstallAppRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }()

    // Roots under ~/Library where app leftovers accumulate. Only *children*
    // of these may be removed — never the roots themselves.
    static let uninstallLeftoverRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appending(path: "Library", directoryHint: .isDirectory)
        return [
            lib.appending(path: "Caches",                  directoryHint: .isDirectory),
            lib.appending(path: "Preferences",             directoryHint: .isDirectory),
            lib.appending(path: "Application Support",      directoryHint: .isDirectory),
            lib.appending(path: "Logs",                     directoryHint: .isDirectory),
            lib.appending(path: "Saved Application State",  directoryHint: .isDirectory),
            lib.appending(path: "Containers",               directoryHint: .isDirectory),
            lib.appending(path: "Group Containers",         directoryHint: .isDirectory),
        ]
    }()

    // Gates every uninstall delete (defense in depth). True only when url is
    // either a *.app directly inside an app root, or strictly inside a
    // leftover root (never a root directory itself).
    static func isSafeToUninstall(url: URL) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard !forbiddenPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return false
        }

        // Case 1: an .app bundle directly inside an app root.
        if url.pathExtension == "app" {
            let parent = url.standardizedFileURL.deletingLastPathComponent()
                .standardizedFileURL.path(percentEncoded: false)
            let appRoot = uninstallAppRoots.contains { root in
                trimSlash(root.path(percentEncoded: false)) == trimSlash(parent)
            }
            if appRoot { return true }
        }

        // Case 2: a child strictly inside a leftover root (not the root itself).
        for root in uninstallLeftoverRoots {
            let rootPath = trimSlash(root.path(percentEncoded: false))
            if path.hasPrefix(rootPath + "/") && trimSlash(path) != rootPath {
                return true
            }
        }
        return false
    }

    private static func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }
}
