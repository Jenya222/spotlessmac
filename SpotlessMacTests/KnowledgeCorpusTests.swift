import XCTest
@testable import SpotlessMac

// Lints the real articles in SpotlessMac/Resources/Knowledge. These rules keep the prompt text safe:
// nothing in the base may tell the model to run destructive commands or call protected folders safe.
final class KnowledgeCorpusTests: XCTestCase {
    static let wave1: Set<String> = [
        "proc.kernel-task", "proc.windowserver", "proc.spotlight-indexing", "proc.photos-analysis",
        "proc.icloud-sync", "proc.backupd", "proc.software-update", "proc.webkit", "proc.virtualization",
        "proc.dev-runtimes", "app.chrome", "app.electron", "app.docker", "app.telegram", "app.xcode",
        "path.user-caches", "path.logs", "path.xcode-deriveddata", "path.xcode-device-support", "path.coresimulator",
        "path.iphone-backups", "path.mobile-documents", "path.photos-library", "path.messages-attachments",
        "path.docker-raw", "path.package-caches", "path.ml-models", "path.project-artifacts", "path.old-installers",
        "path.trash", "path.swap",
        "guide.system-data", "guide.space-not-freed", "guide.memory-pressure", "guide.high-swap",
        "guide.no-ram-cleaners", "guide.slow-after-update", "guide.browser-memory", "guide.login-items",
        "guide.downloads-cleanup", "guide.desktop-organization", "guide.file-organization", "guide.optimize-storage",
        "guide.free-space-target", "guide.caches-explained", "guide.uninstall-apps", "guide.fda",
        "guide.spotlight-exclude", "guide.large-media",
    ]
    static let forbiddenWords = [
        "sudo", "rm", "kill", "killall", "pkill", "launchctl unload", "launchctl bootout", "launchctl remove",
        "defaults write", "defaults delete", "csrutil", "purge", "diskutil erase", "tmutil delete",
    ]
    static let bodyLength = 400...2_500

    static var sourceFiles: [(name: String, text: String)] {
        get throws {
            let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "SpotlessMac/Resources/Knowledge")
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                .filter { $0.hasSuffix(".md") }
                .sorted()
            return try names.map { ($0, try String(contentsOf: folder.appending(path: $0), encoding: .utf8)) }
        }
    }

    func corpus() throws -> KnowledgeBase {
        let (base, failures) = KnowledgeBase.build(files: try Self.sourceFiles)
        XCTAssertEqual(failures, [])
        return base
    }

    func testEveryArticleParses() throws {
        let files = try Self.sourceFiles
        XCTAssertFalse(files.isEmpty)
        let (base, failures) = KnowledgeBase.build(files: files)
        XCTAssertEqual(failures, [])
        XCTAssertEqual(base.articles.count, files.count)
    }

    func testBundledCopyMatchesSources() throws {
        // Unit tests run inside the app (TEST_HOST), so Bundle.main is SpotlessMac.app.
        let bundled = KnowledgeBase.loadBundled(from: .main)
        XCTAssertEqual(bundled.articles.map(\.id), try corpus().articles.map(\.id))
    }

    func testBodyLengthAndSources() throws {
        for article in try corpus().articles {
            XCTAssertTrue(Self.bodyLength.contains(article.body.count), "\(article.id): body \(article.body.count) chars")
            if article.kind != .guide { XCTAssertFalse(article.sources.isEmpty, "\(article.id): no sources") }
            for source in article.sources {
                XCTAssertTrue(source.hasPrefix("https://") || source.hasPrefix("man:"), "\(article.id): \(source)")
            }
        }
    }

    func testRelatedPointToKnownArticles() throws {
        let base = try corpus()
        let known = Set(base.articles.map(\.id)).union(Self.wave1)
        for article in base.articles {
            for id in article.related {
                XCTAssertTrue(known.contains(id), "\(article.id) → unknown \(id)")
                XCTAssertNotEqual(id, article.id)
            }
        }
    }

    func testBindingsMatchKind() throws {
        for article in try corpus().articles {
            switch article.kind {
            case .process:
                XCTAssertFalse(article.processes.isEmpty, "\(article.id): process without process names")
                XCTAssertTrue(article.paths.isEmpty, "\(article.id): process articles carry no paths")
            case .app:
                XCTAssertFalse(article.bundles.isEmpty, "\(article.id): app without bundle IDs")
                XCTAssertTrue(article.paths.isEmpty, "\(article.id): app articles carry no paths")
            case .path:
                XCTAssertFalse(article.paths.isEmpty && article.categories.isEmpty, "\(article.id): unbound path article")
                XCTAssertTrue(article.processes.isEmpty && article.bundles.isEmpty, "\(article.id)")
            case .guide:
                XCTAssertTrue(article.processes.isEmpty && article.bundles.isEmpty && article.paths.isEmpty, "\(article.id)")
                XCTAssertEqual(article.verdict, .info, "\(article.id): guides use verdict info")
            }
        }
    }

    func testNoForbiddenWords() throws {
        for article in try corpus().articles {
            let text = [article.title, article.summary, article.body].joined(separator: "\n")
            for word in Self.forbiddenWords {
                let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}_])"#
                XCTAssertNil(text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                             "\(article.id) contains «\(word)»")
            }
        }
    }

    // The assistant never suggests terminal commands (AssistantGuard hides them in answers anyway),
    // so articles carry none: no code fences, no command lines, no commands in inline code.
    func testNoCodeOrTerminalCommands() throws {
        for article in try corpus().articles {
            for line in article.body.components(separatedBy: "\n") {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).hasPrefix("```"), "\(article.id): code fence")
                XCTAssertFalse(AssistantGuard.looksLikeCommand(line), "\(article.id): command line «\(line)»")
            }
            for span in article.body.matches(of: /`([^`\n]+)`/).map({ String($0.1) }) {
                XCTAssertFalse(AssistantGuard.looksLikeCommand(span), "\(article.id): inline command «\(span)»")
            }
        }
    }
}
