import Foundation
import os

struct ToolOutcome: Equatable, Sendable {
    let resultText: String
    let proposal: PlanProposal?
}

enum AssistantToolbox {
    private static let logger = Logger(subsystem: "com.spotlessmac.app", category: "assistant")

    static func execute(_ call: ToolCall, snapshot: SystemSnapshot, formatPath: (String) -> String) -> ToolOutcome {
        switch AssistantTool.parse(call) {
        case .failure(.unknownTool(let name)):
            logger.warning("Assistant requested unknown tool \(name, privacy: .public)")
            return ToolOutcome(
                resultText: "Ошибка: инструмента «\(name)» не существует. Доступны только list_items, item_details и propose_plan. Удалять файлы, запускать команды и менять систему ассистент не может.",
                proposal: nil
            )
        case .failure(.invalidArguments(let reason)):
            return ToolOutcome(resultText: "Ошибка в аргументах \(call.name): \(reason).", proposal: nil)
        case .success(.listItems(let category, let minBytes, let olderThanDays, let limit)):
            let cutoff = olderThanDays.map { snapshot.takenAt.addingTimeInterval(-Double($0) * 86_400) }
            let matches = snapshot.items.filter { item in
                if let category, item.category != category { return false }
                if let minBytes, item.bytes < minBytes { return false }
                if let cutoff {
                    guard let modified = item.modifiedAt, modified < cutoff else { return false }
                }
                return true
            }
            guard !matches.isEmpty else { return ToolOutcome(resultText: "Ничего не найдено.", proposal: nil) }
            let shown = matches.prefix(limit)
            var applied: [String] = []
            if let category { applied.append("категория: \(category.rawValue)") }
            if let olderThanDays { applied.append("старше \(olderThanDays) дн.") }
            if let minBytes { applied.append("от \(SnapshotRenderer.bytes(minBytes))") }
            let filters = applied.isEmpty ? "" : " (\(applied.joined(separator: "; ")))"
            let header = "Найдено \(matches.count), показано \(shown.count)\(filters). Колонки: ID | путь | размер | категория | политика | изменён | владелец:"
            let lines = shown.map { SnapshotRenderer.itemLine($0, formatPath: formatPath) }
            return ToolOutcome(resultText: ([header] + lines).joined(separator: "\n"), proposal: nil)
        case .success(.itemDetails(let id)):
            guard let item = snapshot.item(shortID: id) else {
                return ToolOutcome(resultText: "Элемент \(id) не найден в снимке.", proposal: nil)
            }
            return ToolOutcome(resultText: SnapshotRenderer.itemCard(item, formatPath: formatPath), proposal: nil)
        case .success(.proposePlan(let proposal)):
            let plan = PlanResolver.resolve(proposal, in: snapshot)
            // The chat shows a card only for a meaningful plan, so the model must not be told one was shown otherwise.
            guard plan.isMeaningful else {
                return ToolOutcome(
                    resultText: "План пуст: ни один элемент не подошёл. Проверь ID и фильтры через list_items. Ничего не удалено.",
                    proposal: nil
                )
            }
            var text = "План показан пользователю карточкой: \(plan.itemIDs.count) элементов, \(SnapshotRenderer.bytes(plan.totalBytes)). Ничего не удалено — пользователь сам проверит список и решит. Кратко объясни план словами."
            if !plan.skipped.isEmpty {
                text += " Пропущено: " + plan.skipped.map { "\($0.label) — \($0.count)" }.joined(separator: ", ") + "."
            }
            if !plan.manualReview.isEmpty {
                text += " Удалять вручную: \(plan.manualReview.count)."
            }
            return ToolOutcome(resultText: text, proposal: proposal)
        }
    }
}
