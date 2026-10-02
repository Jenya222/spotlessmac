import Foundation

enum AssistantMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, depth: Int)
    case numbered(marker: String, text: String)
    case paragraph(String)
    case code(String)
    /// Горизонтальная черта (`---`, `***`, `* * *`, `- - -`).
    case rule
    /// GFM pipe-таблица: строка `|---|` задаёт число колонок и отделяет шапку.
    case table(header: [String], rows: [[String]])
}

/// Разбор Markdown итогов на блоки.
///
/// Один `Text(AttributedString(markdown:, .full))` (как в `ReportView`) теряет
/// блочную структуру: заголовки и пункты списка сливаются в один абзац. Поэтому
/// блоки — наши, а внутри блока `AttributedString(markdown:)` в режиме
/// «только строчная разметка» даёт жирный, курсив и ссылки.
enum AssistantMarkdownBlocks {
    static func parse(_ markdown: String) -> [AssistantMarkdownBlock] {
        var blocks: [AssistantMarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        // Продолжение пункта списка (см. `appendContinuation`) разрешено только
        // сразу после самого пункта или другой его строки-продолжения — пустая
        // строка, заголовок и т.п. сбрасывают этот флаг.
        var previousWasListItem = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        // Отступ строки-продолжения приклеивается к тексту пункта, а не живёт
        // отдельным абзацем: иначе многострочная задача из отчёта LLM рвётся
        // на «- Пункт» + повисший абзац без маркера.
        func appendContinuation(_ text: String) -> Bool {
            guard let last = blocks.last else { return false }
            switch last {
            case let .bullet(existing, depth):
                blocks[blocks.count - 1] = .bullet(text: existing + " " + text, depth: depth)
                return true
            case let .numbered(marker, existing):
                blocks[blocks.count - 1] = .numbered(marker: marker, text: existing + " " + text)
                return true
            default:
                return false
            }
        }

        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                previousWasListItem = false
                index += 1
                continue
            }
            if code != nil {
                code?.append(rawLine)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                previousWasListItem = false
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                previousWasListItem = false
                index += 1
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                previousWasListItem = false
                index += 1
                continue
            }
            if let table = tableBlock(lines, at: index) {
                flushParagraph()
                blocks.append(table.block)
                previousWasListItem = false
                index = table.nextIndex
                continue
            }
            if let item = listItem(rawLine) {
                flushParagraph()
                blocks.append(item)
                previousWasListItem = true
                index += 1
                continue
            }
            if previousWasListItem, indentWidth(rawLine) >= 2, appendContinuation(trimmed) {
                index += 1
                continue
            }
            previousWasListItem = false
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        // Незакрытый ``` — всё равно код: модель оборвала ответ на полуслове.
        if let lines = code {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        return blocks
    }

    /// Табы считаем за 4 пробела — иначе строка-продолжение, вставленная
    /// табом (частый случай при копировании из терминала), не проходит
    /// порог отступа и рассыпается в отдельный абзац.
    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }

    // Пробелы внутри строки убираем перед проверкой: `* * *` и `- - -` —
    // такие же горизонтальные черты, как `***` и `---`, просто с пробелами
    // между символами (частый вывод LLM).
    private static func isRule(_ line: String) -> Bool {
        let collapsed = line.replacingOccurrences(of: " ", with: "")
        guard collapsed.count >= 3 else { return false }
        let charset = Set(collapsed)
        guard let only = charset.first, charset.count == 1 else { return false }
        return "-*_".contains(only)
    }

    private static func heading(_ line: String) -> AssistantMarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> AssistantMarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .bullet(text: body.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: indent / 2)
        }
        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let mark = rest.first, ".)".contains(mark), rest.dropFirst().first == " " else { return nil }
        return .numbered(marker: "\(digits).", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// Пытается разобрать GFM pipe-таблицу, начиная со строки `at`. Строка
    /// `at` — шапка, `at + 1` обязана быть строкой-разделителем (`|---|`,
    /// с опциональными `:` для выравнивания), иначе это не таблица.
    private static func tableBlock(
        _ lines: [String],
        at index: Int
    ) -> (block: AssistantMarkdownBlock, nextIndex: Int)? {
        let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"), index + 1 < lines.count else { return nil }
        let separatorLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
        let separatorCells = splitRow(separatorLine)
        guard !separatorCells.isEmpty, separatorCells.allSatisfy(isTableSeparatorCell) else { return nil }

        let header = splitRow(headerLine)
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let rowLine = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard rowLine.contains("|"), !rowLine.isEmpty else { break }
            rows.append(normalizedRow(splitRow(rowLine), columns: header.count))
            cursor += 1
        }
        return (.table(header: header, rows: rows), cursor)
    }

    private static func splitRow(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparatorCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.first == ":" { body.removeFirst() }
        if body.last == ":" { body.removeLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    // Реплика LLM редко попадает точно в число колонок шапки: короткую
    // строку дополняем пустыми ячейками, длинную — обрезаем, вместо того
    // чтобы ронять всю таблицу или сдвигать колонки.
    private static func normalizedRow(_ cells: [String], columns: Int) -> [String] {
        if cells.count == columns { return cells }
        if cells.count < columns { return cells + Array(repeating: "", count: columns - cells.count) }
        return Array(cells.prefix(columns))
    }
}

