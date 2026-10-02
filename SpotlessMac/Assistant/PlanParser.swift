import Foundation

// Fallback for models without tool calling: a fenced ```spotless-plan JSON block.
enum PlanParser {
    static let fence = "```spotless-plan"

    struct Extraction: Equatable {
        let text: String
        let proposal: PlanProposal?
        let malformed: Bool
    }

    static func extract(from text: String) -> Extraction {
        guard let regex = try? NSRegularExpression(pattern: "```spotless-plan[ \\t]*\\n?([\\s\\S]*?)(?:```|$)") else {
            return Extraction(text: text, proposal: nil, malformed: false)
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return Extraction(text: text, proposal: nil, malformed: false) }

        var proposal: PlanProposal?
        var sawMalformed = false
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if let decoded = PlanProposal.decode(json: String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)) {
                proposal = proposal ?? decoded
            } else {
                sawMalformed = true
            }
        }
        let cleaned = regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(text: cleaned, proposal: proposal, malformed: proposal == nil && sawMalformed)
    }

    static func visibleWhileStreaming(_ text: String) -> String {
        guard let range = text.range(of: fence) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
