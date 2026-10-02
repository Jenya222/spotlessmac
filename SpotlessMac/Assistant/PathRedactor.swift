import Foundation

// Cloud-only redaction: the user name becomes "~", the first folder under
// personal roots becomes "<папка-N>". Aliases are stable within a conversation.
struct PathRedactor: Sendable {
    static let personalRoots: Set<String> = [
        "Documents", "Desktop", "Downloads", "Projects", "MyProjects", "Developer",
        "src", "code", "Movies", "Music", "Pictures",
    ]

    private struct Entry: Sendable {
        let root: String
        let name: String
        let alias: String
    }

    // Bare names shorter than this are never substituted in free text, so a folder
    // called "a" cannot corrupt ordinary words.
    private static let minBareNameLength = 3
    private static let wordBoundary = #"[\p{L}\p{N}_]"#

    let homePath: String
    private var entries: [Entry] = []

    init(homePath: String) {
        var home = homePath
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.homePath = home
    }

    mutating func redact(_ path: String) -> String {
        guard path == homePath || path.hasPrefix(homePath + "/") else { return path }
        var components = path.dropFirst(homePath.count).split(separator: "/").map(String.init)
        if components.count >= 2, Self.personalRoots.contains(components[0]) {
            components[1] = alias(forRoot: components[0], name: components[1])
        }
        return (["~"] + components).joined(separator: "/")
    }

    // Redacts home-based paths and already-known folder names in free text (user
    // messages, history). History may hold assistant answers that were restored to
    // real folder names, so known names are re-aliased even when no home path is present.
    // Residual: an unknown folder name containing spaces is aliased only up to its first
    // space ("~/Documents/Мой проект" -> "~/Documents/<папка-1> проект") unless the name
    // was already registered through redact(_:).
    mutating func redactText(_ text: String) -> String {
        var result = text

        // 1. Home path -> "~", as a path prefix or a bare token. Lookalikes such as
        // "/Users/testerX" or "/Users/tester.bak" stay untouched.
        if homePath.count > 1 {
            let home = NSRegularExpression.escapedPattern(for: homePath)
            result = Self.rewrite(result, pattern: home + #"(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])"#) { _ in "~" }
        }

        // 2. Known (root, name) pairs, longest name first: exact match, so names with spaces work.
        for entry in entries.sorted(by: { $0.name.count > $1.name.count }) {
            let known = NSRegularExpression.escapedPattern(for: "~/\(entry.root)/\(entry.name)")
            result = Self.rewrite(result, pattern: known + "(?!\(Self.wordBoundary))") { _ in
                "~/\(entry.root)/\(entry.alias)"
            }
        }

        // 3. Remaining "~/<personalRoot>/<component>"; the component ends at "/", whitespace
        // or one of |`'"«»,;(). Components that already are aliases are left alone.
        let roots = Self.personalRoots.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pathPattern = #"(?<![\p{L}\p{N}_~])~/("# + roots + #")/([^/\s|`'"«»,;()]+)"#
        result = Self.rewrite(result, pattern: pathPattern) { groups in
            guard !Self.isAliasToken(groups[2]) else { return nil }
            return "~/\(groups[1])/\(alias(forRoot: groups[1], name: groups[2]))"
        }

        // 4. Bare known names as whole words (restored answers mention folders without a path).
        var aliasByName: [String: String] = [:]
        for entry in entries where entry.name.count >= Self.minBareNameLength && !Self.isAliasToken(entry.name) {
            if aliasByName[entry.name] == nil { aliasByName[entry.name] = entry.alias }
        }
        if !aliasByName.isEmpty {
            let names = aliasByName.keys
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            // Alias tokens are matched first so a name that occurs inside one is never touched.
            let barePattern = #"<папка-\d+>|(?<!"# + Self.wordBoundary + ")(?:" + names + ")(?!" + Self.wordBoundary + ")"
            result = Self.rewrite(result, pattern: barePattern) { aliasByName[$0[0]] }
        }
        return result
    }

    func restore(_ text: String) -> String {
        entries.reduce(text) { $0.replacingOccurrences(of: $1.alias, with: $1.name) }
    }

    private mutating func alias(forRoot root: String, name: String) -> String {
        if let existing = entries.first(where: { $0.root == root && $0.name == name }) {
            return existing.alias
        }
        let alias = "<папка-\(entries.count + 1)>"
        entries.append(Entry(root: root, name: name, alias: alias))
        return alias
    }

    private static func isAliasToken(_ text: String) -> Bool {
        text.hasPrefix("<папка-") && text.hasSuffix(">")
    }

    // Replaces each match with `replacement(groups)` (groups[0] is the whole match,
    // missing groups are ""). Matches are visited in text order; nil keeps the match.
    private static func rewrite(_ text: String, pattern: String, replacement: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var edits: [(range: NSRange, text: String)] = []
        for match in matches {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            if let new = replacement(groups) { edits.append((match.range, new)) }
        }
        guard !edits.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        return result as String
    }
}
