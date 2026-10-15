import Foundation

enum AgentStorageCatalog {
    static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentStorageSource] {
        let paths: [(String, String, AgentStorageKind)] = [
            (".codex/worktrees", "Codex", .workspace),
            (".codex/tmp", "Codex", .temporary),
            (".cursor/worktrees", "Cursor", .workspace),
            (".claude/worktrees", "Claude", .workspace),
            (".claude/debug", "Claude", .logs),
            (".claude/projects", "Claude", .sessions),
        ]
        return paths.map { AgentStorageSource(url: home.appending(path: $0.0), agent: $0.1, kind: $0.2) }
            + KnownCacheScanner.locations(home: home).filter { ["Cursor", "Claude"].contains($0.owner) }
                .map { AgentStorageSource(url: $0.url, agent: $0.owner, kind: .cache) }
    }

    static let projectWorktrees: [(path: String, agent: String)] = [
        (".claude/worktrees", "Claude"), (".cursor/worktrees", "Cursor"), (".codex/worktrees", "Codex")
    ]

    /// A broad legacy whitelist must not make managed workspaces deletable.
    static func isProtectedWorkspacePath(_ url: URL) -> Bool {
        for path in [url.standardizedFileURL.path, PathPolicy.canonical(url)] {
            let parts = URL(filePath: path.lowercased()).pathComponents
            if zip(parts, parts.dropFirst()).contains(where: { first, second in
                [".claude", ".cursor", ".codex"].contains(first) && ["worktrees", "projects"].contains(second)
            }) { return true }
        }
        return false
    }
}
