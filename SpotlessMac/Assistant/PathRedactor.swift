import Foundation

// Cloud-only redaction. The user name becomes "~". Under a personal root (a well-known home
// folder such as ~/Documents, or a registered project root) every folder and file name becomes
// "<папка-N>", except well-known artifact directories that carry no personal information
// (node_modules, build, ...). A registered project root itself becomes "<проекты-K>".
// Aliases are stable within a conversation: the same folder always gets the same alias.
struct PathRedactor: Sendable {
    static let personalRoots: Set<String> = [
        "Documents", "Desktop", "Downloads", "Projects", "MyProjects", "Developer",
        "src", "code", "Movies", "Music", "Pictures",
    ]

    // Directory names that say nothing about the user; they stay readable so the model can tell
    // what kind of item it is looking at.
    static let neutralComponents: Set<String> = [
        "node_modules", ".build", "build", "dist", "target", ".venv", "venv", "Pods", "DerivedData",
        ".gradle", "__pycache__", ".next", ".nuxt", ".cache", "vendor",
    ]

    // One aliased folder. `parentKey` identifies the folder's parent by its real names ("Projects/shop",
    // "<проекты-1>/shop"), so equal names in different places get different aliases.
    private struct Entry: Sendable {
        let parentKey: String
        let name: String
        let alias: String
        var key: String { parentKey + "/" + name }
    }

    // Bare names shorter than this are never substituted in free text, so a folder
    // called "a" cannot corrupt ordinary words.
    private static let minBareNameLength = 3
    private static let wordBoundary = #"[\p{L}\p{N}_]"#

    // A path component ends at "/", whitespace or one of |`'"«»,;().
    private static let terminatorUnits: Set<unichar> = Set("/|`'\"«»,;()".utf16)
    // Sentence and markdown punctuation that may directly follow a path in prose.
    private static let trailingPunctuationUnits: Set<unichar> = Set(".:!?*-—–…]}>".utf16)
    private static let slash = unichar(UInt8(ascii: "/"))

    let homePath: String
    // Absolute registered project roots without a trailing slash, longest first.
    private let extraRoots: [String]
    // Registered roots in order of first use: alias number K is index + 1.
    private var rootAliases: [String] = []
    private var entries: [Entry] = []
    private var indexByKey: [String: Int] = [:]
    private var indexByAlias: [String: Int] = [:]

    init(homePath: String, extraRoots: [String] = []) {
        self.homePath = Self.strippingTrailingSlashes(homePath)
        var seen = Set<String>()
        self.extraRoots = extraRoots
            .map(Self.strippingTrailingSlashes)
            .filter { $0.count > 1 && $0.hasPrefix("/") && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    // True for a string that is an absolute path inside the home folder or a registered root.
    func covers(_ path: String) -> Bool {
        extraRoot(containing: path) != nil || path == homePath || path.hasPrefix(homePath + "/")
    }

    mutating func redact(_ path: String) -> String {
        if let root = extraRoot(containing: path) {
            let token = rootAlias(for: root)
            let components = path.dropFirst(root.count).split(separator: "/").map(String.init)
            return aliased(components, after: [token], parentKey: token)
        }
        guard path == homePath || path.hasPrefix(homePath + "/") else { return path }
        let components = path.dropFirst(homePath.count).split(separator: "/").map(String.init)
        guard let first = components.first, Self.personalRoots.contains(first) else {
            return (["~"] + components).joined(separator: "/")
        }
        return aliased(Array(components.dropFirst()), after: ["~", first], parentKey: first)
    }

    // Redacts home-based and registered-root paths and already-known folder names in free text
    // (user messages, history). History may hold assistant answers that were restored to real
    // folder names, so known names are re-aliased even when no home path is present.
    // Residual: an unknown folder name containing spaces is aliased only up to its first
    // space ("~/Documents/Мой проект" -> "~/Documents/<папка-1> проект") unless the name
    // was already registered through redact(_:).
    mutating func redactText(_ text: String) -> String {
        var result = replaceRegisteredRoots(in: text)

        // Home path -> "~", as a path prefix or a bare token. Lookalikes such as
        // "/Users/testerX" or "/Users/tester.bak" stay untouched.
        if homePath.count > 1 {
            let home = NSRegularExpression.escapedPattern(for: homePath)
            result = Self.rewrite(result, pattern: home + #"(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])"#) { _ in "~" }
        }

        result = aliasPathComponents(in: result)

        // Bare known names as whole words (restored answers mention folders without a path).
        var aliasByName: [String: String] = [:]
        for entry in entries where entry.name.count >= Self.minBareNameLength && !Self.isAliasToken(entry.name) {
            if aliasByName[entry.name] == nil { aliasByName[entry.name] = entry.alias }
        }
        if !aliasByName.isEmpty {
            let names = aliasByName.keys
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            // Alias tokens and personal-root prefixes are matched first (and kept), so a name that
            // occurs inside one of them, such as a nested folder called "src", is never touched.
            let barePattern = #"<папка-\d+>|<проекты-\d+>|~/(?:"# + Self.personalRootsPattern + #")(?!"# + Self.wordBoundary + ")"
                + #"|(?<!"# + Self.wordBoundary + ")(?:" + names + ")(?!" + Self.wordBoundary + ")"
            result = Self.rewrite(result, pattern: barePattern) { aliasByName[$0[0]] }
        }
        return result
    }

    func restore(_ text: String) -> String {
        guard !entries.isEmpty || !rootAliases.isEmpty else { return text }
        var originals: [String: String] = [:]
        for entry in entries { originals[entry.alias] = entry.name }
        for (index, root) in rootAliases.enumerated() { originals[Self.rootToken(index + 1)] = root }
        // One pass over the tokens, so a restored name is never scanned for further aliases.
        return Self.rewrite(text, pattern: #"<(?:папка|проекты)-\d+>"#) { originals[$0[0]] }
    }

    // MARK: Aliases

    private static func rootToken(_ number: Int) -> String { "<проекты-\(number)>" }

    private static func strippingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static var personalRootsPattern: String {
        personalRoots.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    private func extraRoot(containing path: String) -> String? {
        extraRoots.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    private mutating func rootAlias(for root: String) -> String {
        if let index = rootAliases.firstIndex(of: root) { return Self.rootToken(index + 1) }
        rootAliases.append(root)
        return Self.rootToken(rootAliases.count)
    }

    // Aliases `components` below the folder identified by `parentKey`; `head` is the already redacted prefix.
    private mutating func aliased(_ components: [String], after head: [String], parentKey: String) -> String {
        var parts = head
        var key = parentKey
        for name in components {
            let step = visit(parent: key, name: name)
            parts.append(step.display)
            key = step.key
        }
        return parts.joined(separator: "/")
    }

    // Returns what to show for the folder `name` inside `parent`, and the folder's own key.
    private mutating func visit(parent: String, name: String) -> (display: String, key: String) {
        let key = parent + "/" + name
        if Self.neutralComponents.contains(name) { return (name, key) }
        if let index = indexByKey[key] { return (entries[index].alias, key) }
        let alias = "<папка-\(entries.count + 1)>"
        entries.append(Entry(parentKey: parent, name: name, alias: alias))
        indexByKey[key] = entries.count - 1
        indexByAlias[alias] = entries.count - 1
        return (alias, key)
    }

    // MARK: Free text

    // Registered roots (absolute, or "~/…" when inside the home folder) -> "<проекты-K>", in text order.
    private mutating func replaceRegisteredRoots(in text: String) -> String {
        guard !extraRoots.isEmpty else { return text }
        var rootByForm: [String: String] = [:]
        for root in extraRoots {
            rootByForm[root] = root
            if homePath.count > 1, root.hasPrefix(homePath + "/") {
                rootByForm["~" + root.dropFirst(homePath.count)] = root
            }
        }
        let forms = rootByForm.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // A root is a whole path prefix: "/Volumes/Ext/clients-old" and ".bak" lookalikes stay untouched.
        let pattern = "(?:" + forms + #")(?![\p{L}\p{N}_-]|\.[\p{L}\p{N}_-])"#
        return Self.rewrite(text, pattern: pattern) { groups in
            rootByForm[groups[0]].map { rootAlias(for: $0) }
        }
    }

    // Finds "~/<personalRoot>/…" and "<проекты-K>/…" and aliases every component after the prefix.
    // No lookbehind: "/System/Volumes/Data/Users/<user>/Documents/x" becomes
    // "/System/Volumes/Data~/Documents/x" once the home path is replaced, and its folders must still be aliased.
    private mutating func aliasPathComponents(in text: String) -> String {
        let headPattern = #"(?:~/(?:"# + Self.personalRootsPattern + #")|<проекты-\d+>)(?=/)"#
        guard let heads = try? NSRegularExpression(pattern: headPattern) else { return text }
        let source = text as NSString
        var result = ""
        var copied = 0
        var searchStart = 0
        while searchStart < source.length,
              let match = heads.firstMatch(in: text, range: NSRange(location: searchStart, length: source.length - searchStart)) {
            let headEnd = NSMaxRange(match.range)
            guard let headKey = key(forHead: source.substring(with: match.range)) else {
                searchStart = headEnd
                continue
            }
            var position = headEnd
            var key = headKey
            var tail = ""
            while position < source.length, source.character(at: position) == Self.slash,
                  let part = nextComponent(in: source, at: position + 1, parentKey: key) {
                tail += "/" + part.display
                key = part.key
                position = part.end
            }
            result += source.substring(with: NSRange(location: copied, length: headEnd - copied)) + tail
            copied = position
            searchStart = position
        }
        guard copied > 0 else { return text }
        return result + source.substring(from: copied)
    }

    // "~/Documents" -> "Documents"; a "<проекты-K>" token counts only for a registered root.
    private func key(forHead head: String) -> String? {
        if head.hasPrefix("~/") { return String(head.dropFirst(2)) }
        guard let number = Int(head.dropFirst("<проекты-".count).dropLast()),
              number >= 1, number <= rootAliases.count else { return nil }
        return head
    }

    // Reads the path component starting at `start` (just after a "/").
    private mutating func nextComponent(in source: NSString, at start: Int, parentKey: String)
        -> (display: String, key: String, end: Int)? {
        guard start < source.length else { return nil }

        // Known names first, longest first, as a whole component: this is what makes names with
        // spaces work and keeps "shop" from matching inside "shop-admin".
        let known = entries.filter { $0.parentKey == parentKey }.sorted { $0.name.count > $1.name.count }
        for entry in known {
            let length = (entry.name as NSString).length
            guard start + length <= source.length,
                  source.substring(with: NSRange(location: start, length: length)) == entry.name,
                  Self.endsComponent(source, at: start + length) else { continue }
            return (entry.alias, entry.key, start + length)
        }

        // An alias token written by the model (or produced earlier): keep it and continue below its folder.
        if source.character(at: start) == unichar(UInt8(ascii: "<")),
           let regex = try? NSRegularExpression(pattern: #"<папка-\d+>"#),
           let token = regex.firstMatch(in: source as String, options: .anchored,
                                        range: NSRange(location: start, length: source.length - start)) {
            let text = source.substring(with: token.range)
            guard let index = indexByAlias[text] else { return nil }
            return (text, entries[index].key, NSMaxRange(token.range))
        }

        // Unknown name: up to the next terminator, without the sentence punctuation that follows it.
        var end = start
        while end < source.length, !Self.isTerminator(source.character(at: end)) { end += 1 }
        while end > start, Self.trailingPunctuationUnits.contains(source.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        let step = visit(parent: parentKey, name: source.substring(with: NSRange(location: start, length: end - start)))
        return (step.display, step.key, end)
    }

    private static func isTerminator(_ unit: unichar) -> Bool {
        if terminatorUnits.contains(unit) { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }

    // A name ends at the end of the text, at a terminator, or at trailing punctuation that is itself
    // followed by a terminator or the end: "big.iso. Это" and "**Мой проект**" end there, "shop-admin" does not end after "shop".
    private static func endsComponent(_ source: NSString, at index: Int) -> Bool {
        guard index < source.length else { return true }
        if isTerminator(source.character(at: index)) { return true }
        var position = index
        while position < source.length, trailingPunctuationUnits.contains(source.character(at: position)) { position += 1 }
        return position > index && (position >= source.length || isTerminator(source.character(at: position)))
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
