import Foundation

enum SafetyRules {
    static let developerCacheRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Developer/Xcode/DerivedData", directoryHint: .isDirectory),
            home.appending(path: "Library/Developer/CoreSimulator/Caches", directoryHint: .isDirectory),
        ]
    }()

    static let legacyAllowedRoots: [URL] = {
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
        ] + developerCacheRoots
    }()

    static var huggingFaceRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub") }
    static var recordingsRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/wooffoow/recordings") }
    static var projectRoots: [URL] { [FileManager.default.homeDirectoryForCurrentUser.appending(path: "MyProjects")] + StorageRootRegistry.roots(kind: .projects) }
    static var huggingFaceRoots: [URL] { [huggingFaceRoot] + StorageRootRegistry.roots(kind: .huggingFace) }
    static func rootIsTrusted(_ root: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let registered = StorageRootRegistry.roots(kind: .projects) + StorageRootRegistry.roots(kind: .huggingFace)
        if registered.contains(where: { PathPolicy.canonical($0) == PathPolicy.canonical(root) }) { return true }
        if PathPolicy.contains(root.standardizedFileURL.path(percentEncoded: false), in: home.standardizedFileURL.path(percentEncoded: false)) {
            return PathPolicy.isUnredirected(root, below: home)
        }
        return !PathPolicy.isForbidden(PathPolicy.canonical(root))
    }
    static var knownCacheRoots: [URL] { KnownCacheScanner.locations(home: FileManager.default.homeDirectoryForCurrentUser).map(\.url) }
    static var allowedRoots: [URL] { legacyAllowedRoots + knownCacheRoots + huggingFaceRoots + [recordingsRoot] + projectRoots }

    static let forbiddenPrefixes: [String] = [
        "/System",
        "/private/var/vm",
        "/dev",
        "/cores",
    ]

    static func isSafe(url: URL) -> Bool {
        let path = PathPolicy.canonical(url)
        guard !PathPolicy.isForbidden(path), StorageFileIdentity.read(url)?.isSymbolicLink != true else { return false }
        if legacyAllowedRoots.contains(where: { rootIsTrusted($0) && PathPolicy.contains(path, in: PathPolicy.canonical($0), includeRoot: false) }) { return true }
        if knownCacheRoots.contains(where: { rootIsTrusted($0) && path == PathPolicy.canonical($0) && StorageFileIdentity.read($0)?.isSymbolicLink != true }) { return true }
        if huggingFaceRoots.contains(where: { rootIsTrusted($0) && PathPolicy.canonical(url.deletingLastPathComponent()) == PathPolicy.canonical($0) }) {
            return HuggingFaceCacheScanner.isRepositoryName(url.lastPathComponent) && StorageFileIdentity.read(url)?.isDirectory == true
        }
        if rootIsTrusted(recordingsRoot) && PathPolicy.canonical(url.deletingLastPathComponent()) == PathPolicy.canonical(recordingsRoot) { return RecordingScanner.isStandalone(url) }
        if projectRoots.contains(where: { rootIsTrusted($0) && PathPolicy.contains(path, in: PathPolicy.canonical($0), includeRoot: false) }) {
            return StorageFileIdentity.read(url)?.isDirectory == true && ProjectArtifactsScanner.hasMarker(url) && !ProjectArtifactsScanner.containsGitMetadata(url)
        }
        return false
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
    static func isSafeToUninstall(url: URL, appRoots: [URL] = uninstallAppRoots,
                                  rootTrust: (URL) -> Bool = rootIsTrusted) -> Bool {
        let path = PathPolicy.canonical(url)
        guard StorageFileIdentity.read(url)?.isSymbolicLink != true else { return false }
        guard !PathPolicy.isForbidden(path) else {
            return false
        }

        // Case 1: an .app bundle directly inside an app root.
        if url.pathExtension == "app" {
            let parent = PathPolicy.canonical(url.deletingLastPathComponent())
            let appRoot = appRoots.contains { root in
                rootTrust(root) && PathPolicy.canonical(root) == trimSlash(parent)
            }
            if appRoot { return true }
        }

        // Case 2: a child strictly inside a leftover root (not the root itself).
        for root in uninstallLeftoverRoots where rootIsTrusted(root) {
            let rootPath = PathPolicy.canonical(root)
            if path.hasPrefix(rootPath + "/") && trimSlash(path) != rootPath {
                return true
            }
        }
        return false
    }

    private static func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func canonicalPath(_ url: URL) -> String {
        trimSlash(url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false))
    }
}
