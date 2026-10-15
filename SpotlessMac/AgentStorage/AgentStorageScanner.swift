import Foundation

struct AgentStorageScanner: Scanner {
    let category: ScanCategory = .agentData
    let home: URL
    let projectRoots: [URL]
    let extraRoots: [URL]
    static let minimumAge: TimeInterval = 7 * 86400
    private static let projectNames: Set<String> = Set([
        "package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "requirements.txt",
        "go.mod", "CMakeLists.txt", "Makefile", "Gemfile", "pom.xml", "build.gradle",
        ".hg", ".svn", ".env", ".project", "AGENTS.md", "CLAUDE.md", "composer.json",
        "build.gradle.kts", "Dockerfile", "docker-compose.yml", "compose.yaml", "deno.json"
    ].map { $0.lowercased() })
    private static let sourceExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "c", "cpp", "h", "java",
        "kt", "rb", "cs", "xcodeproj", "xcworkspace", "ipynb", "html", "htm", "css",
        "scss", "vue", "svelte", "php", "sh", "bash", "zsh", "fish", "ps1", "csproj", "sln"
    ]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         projectRoots: [URL] = SafetyRules.projectRoots.filter(SafetyRules.rootIsTrusted),
         extraRoots: [URL] = StorageRootRegistry.roots(kind: .agentWorkspaces)) {
        self.home = home; self.projectRoots = projectRoots; self.extraRoots = extraRoots
    }

    func scan() async throws -> [ScanItem] {
        // Caches already have their own scanner in the general cleaner.
        try await inventory().items.filter { $0.kind != .cache }.map(\.scanItem)
    }

    func inventory() async throws -> AgentStorageReport {
        try await StorageAnalysisEngine.offMain { try collect() }
    }

    private func collect() throws -> AgentStorageReport {
        let fm = FileManager.default
        var report = AgentStorageReport()
        var sources = AgentStorageCatalog.sources(home: home).filter {
            let trusted = PathPolicy.isUnredirected($0.url, below: home)
            if !trusted { report.warnings.append("Источник перенаправлен ссылкой и пропущен: \($0.url.path)") }
            return trusted
        }
        sources += extraRoots.map { AgentStorageSource(url: $0, agent: "Другие агенты", kind: .workspace) }
        let skipped: Set<String> = [".git", "node_modules", ".build", "build", "vendor", ".venv", "venv", ".cache"]
        // Bounded project discovery; no walk through dependencies or arbitrary disk roots.
        var visited = Set<String>()
        var discoveryCount = 0
        func discover(_ directory: URL, root: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 5, PathPolicy.isUnredirected(directory, below: root),
                  !PathPolicy.isForbidden(PathPolicy.canonical(directory)),
                  StorageFileIdentity.read(directory)?.isDirectory == true,
                  visited.insert(PathPolicy.canonical(directory)).inserted else { return }
            discoveryCount += 1
            guard discoveryCount <= 5_000 else { return }
            for known in AgentStorageCatalog.projectWorktrees {
                let path = directory.appending(path: known.path)
                if PathPolicy.isUnredirected(path, below: root), StorageFileIdentity.read(path)?.isDirectory == true {
                    sources.append(AgentStorageSource(url: path, agent: known.agent, kind: .workspace))
                }
            }
            do {
                for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    if !skipped.contains(child.lastPathComponent), !child.lastPathComponent.hasPrefix(".") {
                        try discover(child, root: root, depth: depth + 1)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.warnings.append("Не удалось проверить папку проектов: \(directory.path)") }
        }
        for root in projectRoots { try discover(root, root: root, depth: 0) }
        if discoveryCount > 5_000 { report.warnings.append("Достигнут лимит поиска папок проектов. Добавьте нужную рабочую папку отдельно.") }

        var candidates: [(URL, AgentStorageSource)] = []
        for source in sources {
            try Task.checkCancellation()
            guard let identity = StorageFileIdentity.read(source.url) else {
                // Distinguish missing tools from permission errors, including unreadable ancestors.
                do { _ = try source.url.resourceValues(forKeys: [.isDirectoryKey]) }
                catch {
                    let error = error as NSError
                    if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                        report.warnings.append("Нет доступа: \(source.url.path)")
                    }
                }
                continue
            }
            guard identity.isDirectory, !identity.isSymbolicLink, !PathPolicy.isForbidden(PathPolicy.canonical(source.url)) else { continue }
            if source.kind == .cache { candidates.append((source.url, source)); continue }
            do {
                let children = try fm.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil)
                for child in children {
                    try appendUnits(child, source: source, depth: source.kind == .workspace ? 2 : 0, to: &candidates)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { report.warnings.append("Нет доступа к источнику: \(source.url.path)") }
        }
        // Prefer enclosing entries so configured/nested sources never double count.
        var accepted: [String] = []
        for (path, source) in candidates.sorted(by: { $0.0.path.count < $1.0.path.count }) {
            try Task.checkCancellation()
            guard PathPolicy.isUnredirected(path, below: source.url), StorageFileIdentity.read(path)?.isSymbolicLink != true else {
                report.warnings.append("Ссылка пропущена: \(path.path)"); continue
            }
            let key = PathPolicy.canonical(path)
            guard !accepted.contains(where: { PathPolicy.contains(key, in: $0) }) else { continue }
            do {
                let item = try Self.inspect(path, source: source, now: report.scannedAt)
                report.items.append(item)
                accepted.append(key)
            } catch is CancellationError { throw CancellationError() }
            catch { report.warnings.append("Не удалось прочитать: \(path.path)") }
        }
        report.items.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        return report
    }

    private func appendUnits(_ url: URL, source: AgentStorageSource, depth: Int,
                             to result: inout [(URL, AgentStorageSource)]) throws {
        try Task.checkCancellation()
        guard PathPolicy.isUnredirected(url, below: source.url),
              let identity = StorageFileIdentity.read(url), !identity.isSymbolicLink else {
            // Keep it for the collector to report explicitly; never follow a link.
            result.append((url, source)); return
        }
        if depth > 0, identity.isDirectory {
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                // inspect emits a partial, read-only row; keep scanning accessible siblings.
                result.append((url, source)); return
            }
            let isProject = children.contains { $0.lastPathComponent.lowercased() == ".git" || Self.isProjectMarker($0) }
            // Codex/Cursor use grouping directories above actual checkouts.
            if !children.isEmpty, !isProject, children.allSatisfy({ StorageFileIdentity.read($0)?.isDirectory == true }) {
                for child in children { try appendUnits(child, source: source, depth: depth - 1, to: &result) }
                return
            }
        }
        result.append((url, source))
    }

    private static func isProjectMarker(_ url: URL) -> Bool {
        projectNames.contains(url.lastPathComponent.lowercased()) || sourceExtensions.contains(url.pathExtension.lowercased())
    }

    /// One bounded metadata walk. Does not follow gitdir pointers, execute Git, or read source contents.
    static func inspect(_ url: URL, source: AgentStorageSource, now: Date = Date(), entryLimit: Int = 200_000) throws -> AgentStorageItem {
        try Task.checkCancellation()
        guard PathPolicy.isUnredirected(url, below: source.url),
              !PathPolicy.isForbidden(PathPolicy.canonical(url)),
              let identity = StorageFileIdentity.read(url), !identity.isSymbolicLink,
              identity.isDirectory || identity.isRegularFile else { throw CocoaError(.fileReadNoPermission) }
        let fm = FileManager.default
        var bytes: Int64 = 0
        var latest: Date?
        var complete = true
        var hasGit = false
        var hasProject = false
        var seen = Set<StorageFileIdentity>()
        var entries = 0
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func visit(_ file: URL) {
            guard let id = StorageFileIdentity.read(file), !id.isSymbolicLink,
                  PathPolicy.isUnredirected(file, below: source.url) else { complete = false; return }
            if file.lastPathComponent.lowercased() == ".git" { hasGit = true }
            if Self.isProjectMarker(file) || AgentStorageCatalog.isProtectedWorkspacePath(file) { hasProject = true }
            if id.isDirectory,
               StorageFileIdentity.read(file.appending(path: "HEAD")) != nil,
               StorageFileIdentity.read(file.appending(path: "objects"))?.isDirectory == true,
               StorageFileIdentity.read(file.appending(path: "refs"))?.isDirectory == true { hasGit = true }
            do {
                let values = try file.resourceValues(forKeys: keys)
                if let date = values.contentModificationDate { latest = max(latest ?? date, date) }
                else { complete = false }
                if id.isRegularFile, seen.insert(id).inserted {
                    if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize { bytes += Int64(size) }
                    else { complete = false }
                } else if !id.isDirectory && !id.isRegularFile { complete = false }
            } catch { complete = false }
        }
        visit(url)
        if identity.isDirectory {
            do { _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch { complete = false }
            if let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
                complete = false; return true
            }) {
                for case let child as URL in walker {
                    try Task.checkCancellation()
                    entries += 1
                    if entries > entryLimit { complete = false; break }
                    visit(child)
                    if StorageFileIdentity.read(child)?.isSymbolicLink == true { walker.skipDescendants() }
                }
            } else { complete = false }
        }
        let disposable = source.kind == .cache || source.kind == .logs
            || (source.kind == .temporary && identity.isRegularFile && ["tmp", "log", "cache"].contains(url.pathExtension.lowercased()))
        let status: AgentStorageStatus
        let reason: String
        if hasGit {
            status = .protected
            reason = "Обнаружен Git-репозиторий или worktree, в том числе вложенный. Незакоммиченная и незапушенная работа не проверялась."
        } else if hasProject {
            status = .protected
            reason = "Обнаружены исходники или признаки проекта. Отсутствие Git не делает эти данные мусором."
        } else if source.kind == .sessions {
            status = .protected; reason = "История диалогов и состояние сессий. Может понадобиться для продолжения работы."
        } else if !complete {
            status = .review; reason = "Обход неполный, есть ссылка, ошибка чтения или превышен лимит. Размер — нижняя оценка."
        } else if !disposable {
            status = .review; reason = "Рабочие или неизвестные данные. Безопасность удаления не подтверждена."
        } else if let latest, now.timeIntervalSince(latest) >= minimumAge {
            status = .cleanable; reason = "Известные временные данные, без признаков проекта и Git; не менялись минимум 7 дней. Закройте агент перед очисткой."
        } else {
            status = .recent; reason = "Файлы менялись за последние 7 дней и могут использоваться агентом."
        }
        let recommendation: String
        if hasGit {
            recommendation = "Проверьте изменения и сохраните коммиты. Удаляйте или переносите worktree штатными средствами агента/Git, чтобы сохранить связи."
        } else if source.kind == .sessions {
            recommendation = "Проверьте настройки хранения истории в агенте; перед архивированием сохраните нужные диалоги."
        } else if bytes >= 1_000_000_000 && status != .cleanable {
            recommendation = "Крупная папка: после завершения работы сделайте проверенный архив на внешнем диске. Путь может использоваться агентом — перенос согласуйте в его настройках."
        } else if status == .cleanable {
            recommendation = "После просмотра можно переместить в Корзину. Кэш будет создан заново при следующем запуске."
        } else {
            recommendation = "Откройте папку в Finder и проверьте назначение. Активные проекты оставьте на месте; завершённые можно архивировать."
        }
        let item = ScanItem(path: url, size: bytes, category: .agentData, modifiedAt: latest, isSelected: false,
                            cleanupPolicy: CleanupPolicy(disposition: status == .cleanable ? .rebuildable : .inspectOnly,
                                                         reason: reason, requiresClosedOwner: true), owner: source.agent)
        return AgentStorageItem(path: url, agent: source.agent, kind: source.kind, bytes: bytes,
                                modifiedAt: latest, isComplete: complete, hasGit: hasGit, status: status,
                                reason: reason, recommendation: recommendation, scanItem: item)
    }

    /// Called again at the deletion boundary; a stale UI label never grants deletion rights.
    static func isSafeCandidate(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Bool {
        guard PathPolicy.isUnredirected(url, below: home), !AgentStorageCatalog.isProtectedWorkspacePath(url) else { return false }
        for source in AgentStorageCatalog.sources(home: home) where [.cache, .logs, .temporary].contains(source.kind) {
            guard PathPolicy.isUnredirected(source.url, below: home) else { continue }
            let matches = source.kind == .cache
                ? PathPolicy.canonical(url) == PathPolicy.canonical(source.url)
                : PathPolicy.canonical(url.deletingLastPathComponent()) == PathPolicy.canonical(source.url)
            if matches { return (try? inspect(url, source: source, now: now).status) == .cleanable }
        }
        return false
    }
}
