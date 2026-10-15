import XCTest
@testable import SpotlessMac

final class AgentStorageTests: XCTestCase {
    private let fm = FileManager.default
    private let now = Date()
    private func fixture(_ files: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appending(path: "agent-storage-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            let url = root.appending(path: file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        return root
    }
    private func age(_ root: URL) throws {
        let old = now.addingTimeInterval(-30 * 86400)
        let walker = try XCTUnwrap(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let child as URL in walker { try fm.setAttributes([.modificationDate: old], ofItemAtPath: child.path) }
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: root.path)
    }
    private func inspect(_ root: URL, kind: AgentStorageKind = .cache, limit: Int = 100_000) throws -> AgentStorageItem {
        try AgentStorageScanner.inspect(root, source: AgentStorageSource(url: root, agent: "Codex", kind: kind), now: now, entryLimit: limit)
    }

    func testOldCacheIsCandidateAndNeverSelectedByDefault() throws {
        let root = try fixture(["data/blob"]); try age(root)
        let item = try inspect(root)
        XCTAssertEqual(item.status, .cleanable)
        XCTAssertGreaterThan(item.bytes, 0)
        XCTAssertFalse(item.scanItem.isSelected)
        XCTAssertTrue(item.scanItem.cleanupPolicy.requiresClosedOwner)
    }

    func testAllGitShapesAreProtectedEvenWhenOld() throws {
        for marker in [".git/HEAD", ".git", "nested/.git", ".GIT/HEAD", "HEAD"] {
            let root = try fixture(marker == "HEAD" ? ["HEAD", "objects/blob", "refs/main"] : [marker])
            try age(root)
            let item = try inspect(root)
            XCTAssertEqual(item.status, .protected, marker)
            XCTAssertTrue(item.hasGit, marker)
            XCTAssertFalse(item.scanItem.cleanupPolicy.canDelete)
        }
    }

    func testProjectWithoutGitAndUnknownWorkspaceAreProtected() throws {
        for marker in ["package.json", "nested/Package.swift", "src/main.py", "project.xcodeproj/project.pbxproj",
                       "index.html", "styles.css", "main.php", "script.sh", "composer.json", "app.csproj", "build.gradle.kts"] {
            let root = try fixture([marker]); try age(root)
            XCTAssertEqual(try inspect(root).status, .protected)
        }
        let root = try fixture(["notes.txt"]); try age(root)
        XCTAssertFalse(try inspect(root, kind: .workspace).scanItem.cleanupPolicy.canDelete)
        XCTAssertFalse(try inspect(root, kind: .sessions).scanItem.cleanupPolicy.canDelete)
        XCTAssertFalse(try inspect(root, kind: .temporary).scanItem.cleanupPolicy.canDelete)
    }

    func testRecentNestedFileOverridesOldDirectory() throws {
        let root = try fixture(["nested/blob"]); try age(root)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: root.appending(path: "nested/blob").path)
        XCTAssertEqual(try inspect(root).status, .recent)
    }

    func testSymlinksAndTruncatedScanNeverAllowCleanup() throws {
        let root = try fixture(["blob"]); try age(root)
        try fm.createSymbolicLink(at: root.appending(path: "redirect"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertEqual(try inspect(root).status, .review)
        XCTAssertFalse(try inspect(root).scanItem.cleanupPolicy.canDelete)
        let other = try fixture(["a", "b"]); try age(other)
        XCTAssertFalse(try inspect(other, limit: 1).isComplete)
        XCTAssertFalse(try inspect(other, limit: 1).scanItem.cleanupPolicy.canDelete)
    }

    func testKnownRootsAndProjectWorktreesDoNotDoubleCount() async throws {
        let home = try fixture([".codex/worktrees/group/repo/.git", "MyProjects/app/.claude/worktrees/task/.git", ".cursor/worktrees/app/task/.git"])
        let report = try await AgentStorageScanner(home: home, projectRoots: [home.appending(path: "MyProjects"), home.appending(path: "MyProjects/app")], extraRoots: []).inventory()
        XCTAssertEqual(report.items.filter { $0.kind == .workspace }.count, 3)
        XCTAssertTrue(report.items.allSatisfy { !$0.scanItem.cleanupPolicy.canDelete })
        XCTAssertEqual(Set(report.items.map(\.id)).count, report.items.count)
    }

    func testSafetyRejectsWorkspaceAndRechecksNewGit() throws {
        let home = try fixture([".codex/tmp/old.tmp", ".codex/worktrees/task/blob"])
        try age(home)
        let file = home.appending(path: ".codex/tmp/old.tmp")
        XCTAssertTrue(AgentStorageScanner.isSafeCandidate(file, home: home, now: now))
        XCTAssertFalse(AgentStorageScanner.isSafeCandidate(home.appending(path: ".codex/worktrees/task"), home: home, now: now))
        let cache = home.appending(path: "Library/Application Support/Cursor/Cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try age(cache)
        XCTAssertTrue(AgentStorageScanner.isSafeCandidate(cache, home: home, now: now))
        try Data().write(to: cache.appending(path: ".git"))
        XCTAssertFalse(AgentStorageScanner.isSafeCandidate(cache, home: home, now: now))
    }

    func testProjectWorktreeRemainsProtectedUnderLegacyDownloadsRoot() {
        let home = fm.homeDirectoryForCurrentUser
        XCTAssertFalse(SafetyRules.isSafe(url: home.appending(path: "Downloads/example/.claude/worktrees/task/file.txt")))
        XCTAssertFalse(SafetyRules.isSafe(url: home.appending(path: "Documents/example/.cursor/worktrees/task")))
    }

    func testForgedCleanupPolicyCannotBypassAgentAdmission() async throws {
        let root = try fixture(["important.txt"])
        let item = ScanItem(path: root, size: 1, category: .agentData,
                            cleanupPolicy: .init(disposition: .rebuildable, reason: "Forged", requiresClosedOwner: false))
        let engine = ScanEngine(validate: { _ in nil }, trash: { _ in XCTFail("Must not reach trash") })
        let failures = await engine.delete(items: [item])
        XCTAssertEqual(failures.count, 1)
    }

    func testRedirectedManagedSourceIsSkippedWithWarning() async throws {
        let home = try fixture(["outside/repo/.git"])
        try fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".codex/worktrees"), withDestinationURL: home.appending(path: "outside"))
        let report = try await AgentStorageScanner(home: home, projectRoots: [], extraRoots: []).inventory()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testAliasAndContainingDirectoriesCannotHideProtectedWorkspace() throws {
        let root = try fixture(["app/.claude/worktrees/task/node_modules/blob", "app/.claude/worktrees/task/package.json"])
        let task = root.appending(path: "app/.claude/worktrees/task")
        let alias = root.appending(path: "alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: task)
        XCTAssertTrue(AgentStorageCatalog.isProtectedWorkspacePath(alias.appending(path: "node_modules")))
        XCTAssertTrue(ProjectArtifactsScanner.containsGitMetadata(root))
        try age(root)
        XCTAssertFalse(try inspect(root).scanItem.cleanupPolicy.canDelete)
        XCTAssertTrue(SafetyRules.protectsAgentWorkspace(root, registeredRoots: [task]))
        XCTAssertTrue(SafetyRules.protectsAgentWorkspace(task.appending(path: "blob"), registeredRoots: [task]))
        XCTAssertFalse(SafetyRules.protectsAgentWorkspace(root.appending(path: "sibling"), registeredRoots: [task]))
    }

    func testUnreadableWorkspaceDoesNotHideSiblingAndLinksAreReported() async throws {
        let home = try fixture([".codex/worktrees/denied/blob", ".codex/worktrees/visible/.git"])
        let denied = home.appending(path: ".codex/worktrees/denied")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }
        try fm.createSymbolicLink(at: home.appending(path: ".codex/worktrees/redirect"), withDestinationURL: home.appending(path: ".codex/worktrees/visible"))
        let report = try await AgentStorageScanner(home: home, projectRoots: [], extraRoots: []).inventory()
        XCTAssertTrue(report.items.contains { $0.path.lastPathComponent == "visible" && $0.hasGit })
        XCTAssertTrue(report.items.contains { $0.path.lastPathComponent == "denied" && !$0.isComplete })
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testUninstallProtectionIncludesCacheAncestorsAndDescendants() throws {
        let root = try fixture(["Cursor/Cache/nested/.git", "Cursor/Cache/blob"])
        let cache = root.appending(path: "Cursor/Cache")
        let sources = [AgentStorageSource(url: cache, agent: "Cursor", kind: .cache)]
        for path in [root, cache, cache.appending(path: "blob")] {
            XCTAssertTrue(SafetyRules.protectsAgentCacheProject(path, sources: sources))
        }
        XCTAssertFalse(SafetyRules.protectsAgentCacheProject(root.appending(path: "sibling"), sources: sources))
    }
}
