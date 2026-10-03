import Foundation

// Prompt-injection defences (OWASP LLM01). The assistant already has no capability that could hurt
// the user — tools only read the snapshot, plans are re-checked by PlanResolver, links are not
// clickable — so these layers keep it on topic and keep untrusted text in its place:
// - input: obvious injection or app-internals requests are answered locally, never sent to the model;
// - data: snapshot and tool output are fenced with a per-answer random boundary ("spotlighting")
//   and cleaned of invisible characters, so file and app names cannot pose as instructions;
// - output: a leaked system prompt is replaced with a refusal, and code or terminal commands are
//   hidden, since deleting is done only in SpotlessMac, to the Trash.
// None of this is a guarantee against a determined jailbreak; it narrows what one can achieve.
enum AssistantGuard {
    static let refusal = """
    Я помогаю только с местом на диске, очисткой и памятью этого Mac — с этим вопросом помочь не могу. \
    Спросите, например, что занимает место или что можно безопасно удалить.
    """

    static let hiddenCodeNotice = """
    _Код и команды терминала скрыты: ассистент не пишет программы и не предлагает команды — \
    удаление выполняется только в SpotlessMac, в Корзину._
    """

    // Per-answer random values: the data boundary and the canary that marks the system prompt.
    struct Tokens: Equatable, Sendable {
        let boundary: String
        let canary: String

        static func random() -> Tokens {
            Tokens(boundary: hex(8), canary: "SM-" + hex(12).uppercased())
        }

        private static func hex(_ count: Int) -> String {
            String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(count))
        }

        var openTag: String { "<данные-\(boundary)>" }
        var closeTag: String { "</данные-\(boundary)>" }
    }

    // MARK: Input

    private static let injectionPatterns: [NSRegularExpression] = [
        // Overriding the rules.
        #"\b(ignore|disregard|forget|override|bypass)\b.{0,40}\b(instructions?|rules|prompts?|guidelines|directives)\b"#,
        #"(игнорир|проигнорир|забудь|забыть|отмени|отменить|не обращай внимания на|обойди|обойти|нарушь).{0,40}(инструкц|правил|указани|промпт|ограничени)"#,
        // Extracting the prompt.
        #"\b(system|developer|hidden|initial)\s+(prompt|instructions?)\b"#,
        #"\b(reveal|show|print|repeat|output|tell me)\b.{0,30}\b(your|the)\s+(instructions|prompt|rules)\b"#,
        #"(системн|скрыт|исходн|изначальн)\w*\s+(промпт|инструкц|подсказк)"#,
        #"(покажи|выведи|повтори|напиши|раскрой|перескажи|процитируй).{0,30}(сво|твои|твоих|эти|этих)\w*\s+(инструкц|правил|промпт)"#,
        // Changing the role.
        #"\b(you are now|act as|pretend (to be|you are)|roleplay as|do anything now|jailbreak)"#,
        #"(теперь ты|ты теперь|притворись|сыграй роль|веди себя как|джейлбрейк)"#,
        // The app's own internals.
        #"\b(source code|codebase)\b.{0,30}\b(spotless|this app|your)"#,
        #"(исходн\w* код|кодов\w* баз|архитектур)\w*.{0,30}(spotless|этого приложени|этой программ|тебя|твой|твоего|твоя)"#,
        #"как\s+(написан|устроен|сделан|запрограммирован)\w*\s+(spotless\w*|(это|эта|этот)\s+(приложени|программ)\w*|ты)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    // True for a message that tries to override the rules, extract the prompt or the app's internals.
    // Such a message is answered with `refusal` locally and is never sent to the model.
    static func isInjectionAttempt(_ text: String) -> Bool {
        let normalized = normalize(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        return injectionPatterns.contains { $0.firstMatch(in: normalized, range: range) != nil }
    }

    // MARK: Untrusted data (spotlighting)

    // Wraps snapshot or tool output in the per-answer boundary after cleaning it.
    static func fence(_ text: String, tokens: Tokens) -> String {
        "\(tokens.openTag)\n\(sanitizeUntrusted(text))\n\(tokens.closeTag)"
    }

    private static let boundaryLookalike = try? NSRegularExpression(pattern: #"<\s*/?\s*данные[^>\n]*>?"#, options: [.caseInsensitive])

    // Removes invisible characters (zero-width, bidi overrides, Unicode tag characters) and anything
    // that looks like a data boundary, so a file name can neither hide text nor close the fence.
    static func sanitizeUntrusted(_ text: String) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter(isVisible)))
        guard let regex = boundaryLookalike else { return visible }
        return regex.stringByReplacingMatches(in: visible, range: NSRange(visible.startIndex..., in: visible), withTemplate: "[…]")
    }

    // MARK: Output

    struct Screened: Equatable {
        let text: String
        let leaked: Bool
    }

    // Final pass over a model answer: a leaked prompt becomes `refusal`, code and commands are hidden.
    static func screen(_ text: String, tokens: Tokens) -> Screened {
        if leaksPrompt(text, tokens: tokens) { return Screened(text: refusal, leaked: true) }
        return Screened(text: hidingCode(text), leaked: false)
    }

    // The canary is in the system prompt only, so seeing it, or two verbatim rule lines, means
    // the prompt is being repeated. One line alone is not enough: the model may rightly say that
    // deleted items go to the Trash in the very words of the rules.
    static func leaksPrompt(_ text: String, tokens: Tokens) -> Bool {
        if text.localizedCaseInsensitiveContains(tokens.canary) { return true }
        let answer = normalize(text)
        let quoted = promptLines.filter { answer.contains($0) }
        return quoted.count >= 2
    }

    private static let promptLines: [String] = {
        let rules = AssistantPrompt.base + "\n" + AssistantPrompt.guardrails(tokens: Tokens(boundary: "", canary: ""))
        return rules.components(separatedBy: "\n")
            .map { normalize($0).trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }
            .filter { $0.count >= 40 }
    }()

    // Hides fenced blocks with program code or terminal commands, inline `commands` and bare
    // `sudo …` / `rm -…` lines. Fences that hold only paths or plain text stay. An unclosed fence
    // (still streaming) is judged by what has arrived so far.
    static func hidingCode(_ text: String) -> String {
        var output: [String] = []
        var block: (info: String, lines: [String], fence: String)?

        func closeBlock() {
            guard let current = block else { return }
            block = nil
            if isCode(info: current.info, lines: current.lines) {
                appendNotice()
            } else {
                output.append(current.fence)
                output.append(contentsOf: current.lines)
                output.append("```")
            }
        }
        func appendNotice() {
            if output.last != hiddenCodeNotice { output.append(hiddenCodeNotice) }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if block != nil {
                    closeBlock()
                } else {
                    block = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [], line)
                }
                continue
            }
            if block != nil {
                block?.lines.append(line)
                continue
            }
            if isBareCommandLine(trimmed) {
                appendNotice()
            } else {
                output.append(hidingInlineCommands(line))
            }
        }
        if let open = block {
            // Still streaming: show the opening of a harmless block, hide a code one.
            if isCode(info: open.info, lines: open.lines) {
                appendNotice()
            } else {
                output.append(open.fence)
                output.append(contentsOf: open.lines)
            }
        }
        return output.joined(separator: "\n")
    }

    private static let plainInfos: Set<String> = ["", "text", "txt", "plain", "plaintext", "markdown", "md"]

    private static func isCode(info: String, lines: [String]) -> Bool {
        let language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if !plainInfos.contains(language) { return true }
        return lines.contains { looksLikeCommand($0) || looksLikeProgramCode($0) }
    }

    // Terminal programs the assistant must never hand to the user: deleting outside the Trash,
    // changing the system or running scripts. Harmless ones (ls, du) are here too — the assistant
    // does not suggest commands at all.
    static let shellCommands: Set<String> = [
        "rm", "rmdir", "srm", "unlink", "mv", "cp", "dd", "ln", "chmod", "chown", "chflags", "mkfs",
        "diskutil", "tmutil", "hdiutil", "csrutil", "spctl", "nvram", "pmset", "launchctl", "defaults",
        "killall", "kill", "pkill", "osascript", "curl", "wget", "bash", "sh", "zsh", "fish", "python",
        "python3", "perl", "ruby", "node", "npm", "npx", "yarn", "pip", "pip3", "brew", "docker", "git",
        "xattr", "find", "xargs", "sqlite3", "open", "sudo", "su", "softwareupdate", "mdutil", "purge",
        "du", "df", "ls", "cd", "cat", "echo", "export", "truncate", "shred", "eval", "source", "xcrun",
    ]

    // "rm -rf ~/x", "$ sudo du -sh", "/bin/rm x": a known command followed by arguments.
    static func looksLikeCommand(_ line: String) -> Bool {
        var tokens = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first == "$" || tokens.first == "%" { tokens.removeFirst() }
        if let first = tokens.first, first.hasPrefix("$"), first.count > 1 { tokens[0] = String(first.dropFirst()) }
        var sudo = false
        if tokens.first == "sudo" { tokens.removeFirst(); sudo = true }
        guard let first = tokens.first else { return sudo }
        let name = (first.split(separator: "/").last.map(String.init) ?? first).lowercased()
        return shellCommands.contains(name) && (tokens.count >= 2 || sudo)
    }

    // A line that starts like a declaration or statement, or ends like one, in the usual languages.
    private static let programCode = try? NSRegularExpression(pattern: [
        #"^\s*(import\s+\w|@import\b|#include|#import|#!|//|func\s+\w|def\s+\w|class\s+\w|struct\s+\w|enum\s+\w"#,
        #"protocol\s+\w|extension\s+\w|(let|var|const)\s+\w+\s*[=:]|function\b|(public|private|static)\s"#,
        #"package\s+\w|using\s+\w|return\b|guard\s|if\s*\(|if\s+let\b|for\s*\(|for\s+\w+\s+in\b|while\s*\("#,
        #"try\b|catch\b|\}|\{\s*$)|[;{]\s*$|\)\s*->|=>"#,
    ].joined(separator: "|"))

    static func looksLikeProgramCode(_ line: String) -> Bool {
        guard let programCode else { return false }
        return programCode.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static let bareCommand = try? NSRegularExpression(pattern: #"^(?:[-*+]\s+|\d+[.)]\s+)?(?:\$\s+)?(?:sudo\s+\S|rm\s+-)"#)

    private static func isBareCommandLine(_ trimmed: String) -> Bool {
        guard let bareCommand else { return false }
        return bareCommand.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static let inlineCode = try? NSRegularExpression(pattern: "`([^`\\n]+)`")

    private static func hidingInlineCommands(_ line: String) -> String {
        guard let inlineCode, line.contains("`") else { return line }
        var result = line
        let matches = inlineCode.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            if looksLikeCommand(String(result[inner])) { result.replaceSubrange(whole, with: "«команда скрыта»") }
        }
        return result
    }

    // MARK: Text normalization

    // Lowercased, compatibility-folded (full-width letters), invisible characters removed, "ё" → "е",
    // whitespace collapsed — so trivial obfuscation does not slip past the patterns.
    static func normalize(_ text: String) -> String {
        let folded = String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter(isVisible)))
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Format characters (Cf: zero-width, bidi controls, tag characters) and control characters other
    // than newline and tab are invisible to the user but readable by the model.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return true }
        switch scalar.properties.generalCategory {
        case .format, .control, .privateUse, .unassigned: return false
        default: return true
        }
    }
}
