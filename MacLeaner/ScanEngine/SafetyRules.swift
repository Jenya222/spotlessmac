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
}
