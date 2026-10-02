import Foundation

// Cloud-only redaction: the user name becomes "~", the first folder under
// personal roots becomes "<папка-N>". Aliases are stable within a conversation.
struct PathRedactor: Sendable {
    static let personalRoots: Set<String> = [
        "Documents", "Desktop", "Downloads", "Projects", "MyProjects", "Developer",
        "src", "code", "Movies", "Music", "Pictures",
    ]

    let homePath: String
    private var aliasByKey: [String: String] = [:]
    private var nameByAlias: [String: String] = [:]

    init(homePath: String) {
        var home = homePath
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.homePath = home
    }

    mutating func redact(_ path: String) -> String {
        guard path == homePath || path.hasPrefix(homePath + "/") else { return path }
        var components = path.dropFirst(homePath.count).split(separator: "/").map(String.init)
        if components.count >= 2, Self.personalRoots.contains(components[0]) {
            let key = components[0] + "/" + components[1]
            let alias: String
            if let existing = aliasByKey[key] {
                alias = existing
            } else {
                alias = "<папка-\(aliasByKey.count + 1)>"
                aliasByKey[key] = alias
                nameByAlias[alias] = components[1]
            }
            components[1] = alias
        }
        return (["~"] + components).joined(separator: "/")
    }

    // Redacts home-based paths embedded in free text (user messages, history).
    mutating func redactText(_ text: String) -> String {
        guard text.contains(homePath) else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: homePath) + #"(?![^/\s])(?:/[^\s|`'"«»,;()]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: redact(String(result[range])))
        }
        return result
    }

    func restore(_ text: String) -> String {
        nameByAlias.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
