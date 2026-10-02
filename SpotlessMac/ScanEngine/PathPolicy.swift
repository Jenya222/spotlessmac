import Foundation
import Darwin

struct PathPolicy: Sendable {
    let readRoots: [URL]
    static func canonical(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        var tail: [String] = []
        // realpath handles /var -> /private/var consistently, including directory URLs.
        while true {
            if let resolved = realpath(path, nil) {
                let base = String(cString: resolved); free(resolved)
                let value = tail.reversed().reduce(base) { URL(filePath: $0).appending(path: $1).path(percentEncoded: false) }
                return value == "/" ? value : value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash
            }
            if path == "/" { return url.standardizedFileURL.path(percentEncoded: false) }
            let part = URL(filePath: path)
            tail.append(part.lastPathComponent)
            path = part.deletingLastPathComponent().path(percentEncoded: false)
            if path.count > 1 { path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash }
        }
    }
    static func contains(_ path: String, in root: String, includeRoot: Bool = true) -> Bool {
        (includeRoot && path == root) || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    static func isForbidden(_ path: String) -> Bool {
        SafetyRules.forbiddenPrefixes.contains { contains(path, in: $0) }
    }
    static func isUnredirected(_ url: URL, below anchor: URL) -> Bool {
        let lexical = url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let anchorPath = anchor.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard lexical == anchorPath || lexical.hasPrefix(anchorPath + "/") else { return false }
        let suffix = String(lexical.dropFirst(anchorPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = canonical(anchor)
        let expected = suffix.isEmpty ? base : base + "/" + suffix
        return canonical(url) == expected
    }

    func canRead(_ url: URL) -> Bool {
        let path = Self.canonical(url)
        guard !Self.isForbidden(path) else { return false }
        return readRoots.contains {
            let root = Self.canonical($0)
            return root != "/" && !Self.isForbidden(root) && Self.contains(path, in: root)
        }
    }
}

private extension String {
    var withLeadingSlash: String { "/" + self }
}
