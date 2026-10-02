import Foundation

enum ToolParseError: Error, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
}

// The complete set of tools the model may call. All of them read the
// in-memory snapshot only; there is intentionally no tool that changes anything.
enum AssistantTool: Equatable, Sendable {
    case listItems(category: ScanCategory?, minBytes: Int64?, olderThanDays: Int?, limit: Int)
    case itemDetails(id: String)
    case proposePlan(PlanProposal)

    static let names = ["list_items", "item_details", "propose_plan"]

    static let specs: [ToolSpec] = {
        let categories = ScanCategory.allCases.map(\.rawValue)
        let listItems: [String: Any] = [
            "type": "object",
            "properties": [
                "category": ["type": "string", "enum": categories, "description": "Категория из снимка"],
                "minBytes": ["type": "integer", "description": "Минимальный размер в байтах"],
                "olderThanDays": ["type": "integer", "description": "Не изменялся дольше N дней"],
                "limit": ["type": "integer", "description": "Сколько вернуть, 1–200, по умолчанию 50"],
            ],
        ]
        let itemDetails: [String: Any] = [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "ID элемента, например c12"]],
            "required": ["id"],
        ]
        let proposePlan: [String: Any] = [
            "type": "object",
            "properties": [
                "items": ["type": "array", "items": ["type": "string"], "description": "ID элементов из снимка"],
                "filters": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "category": ["type": "string", "enum": categories],
                            "olderThanDays": ["type": "integer"],
                            "minBytes": ["type": "integer"],
                        ],
                        "required": ["category"],
                    ],
                ],
                "reason": ["type": "string", "description": "Кратко, почему это безопасно"],
            ],
            "required": ["reason"],
        ]
        return [
            ToolSpec(name: "list_items", description: "Найти найденные сканированием элементы по категории, размеру и возрасту.", parametersJSON: JSONText.string(from: listItems)),
            ToolSpec(name: "item_details", description: "Подробности об элементе снимка по его ID.", parametersJSON: JSONText.string(from: itemDetails)),
            ToolSpec(name: "propose_plan", description: "Предложить пользователю план очистки. Ничего не удаляет: пользователь сам проверит список.", parametersJSON: JSONText.string(from: proposePlan)),
        ]
    }()

    static func parse(_ call: ToolCall) -> Result<AssistantTool, ToolParseError> {
        guard names.contains(call.name) else { return .failure(.unknownTool(call.name)) }
        guard let arguments = JSONText.object(from: call.argumentsJSON) as? [String: Any] else {
            return .failure(.invalidArguments("аргументы должны быть JSON-объектом"))
        }
        switch call.name {
        case "list_items":
            var category: ScanCategory?
            if let raw = arguments["category"] as? String {
                guard let parsed = ScanCategory(rawValue: raw) else { return .failure(.invalidArguments("неизвестная категория \(raw)")) }
                category = parsed
            }
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), 200)
            return .success(.listItems(
                category: category,
                minBytes: (arguments["minBytes"] as? NSNumber)?.int64Value,
                olderThanDays: (arguments["olderThanDays"] as? NSNumber)?.intValue,
                limit: limit
            ))
        case "item_details":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.invalidArguments("нужен id")) }
            return .success(.itemDetails(id: id))
        default:
            guard let proposal = PlanProposal.decode(json: call.argumentsJSON) else {
                return .failure(.invalidArguments("неверный формат плана"))
            }
            return .success(.proposePlan(proposal))
        }
    }
}
