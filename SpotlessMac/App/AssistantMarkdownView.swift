import SwiftUI

struct AssistantMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AssistantMarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(.system(size: level <= 2 ? 15 : 13, weight: .semibold))
                .padding(.top, 4)
        case let .bullet(text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(Self.inline(text))
            }
            .font(.system(size: 13))
            .padding(.leading, CGFloat(depth) * 12)
        case let .numbered(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(Self.inline(text))
            }
            .font(.system(size: 13))
        case let .paragraph(text):
            Text(Self.inline(text)).font(.system(size: 13))
        case let .code(text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.trackBackground, in: RoundedRectangle(cornerRadius: Theme.radiusChip))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(header, rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.inline(cell)).fontWeight(.semibold)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                        }
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    /// Bold, italic and code only. Links in model output are rendered as plain text: the
    /// assistant must not be able to put a clickable URL in front of the user.
    nonisolated static func inline(_ text: String) -> AttributedString {
        guard var result = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        for run in result.runs where run.link != nil {
            result[run.range].link = nil
        }
        return result
    }
}
