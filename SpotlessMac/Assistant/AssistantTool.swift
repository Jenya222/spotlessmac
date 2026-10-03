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
    case lookupKnowledge(id: String?, query: String?)

    static let names = ["list_items", "item_details", "propose_plan", "lookup_knowledge"]

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
        let lookupKnowledge: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "ID статьи справки, например proc.kernel-task или из колонки «справка»"],
                "query": ["type": "string", "description": "Вопрос или ключевые слова по-русски: процесс, папка, программа, проблема"],
            ],
        ]
        return [
            ToolSpec(name: "list_items", description: "Найти найденные сканированием элементы по категории, размеру и возрасту.", parametersJSON: JSONText.string(from: listItems)),
            ToolSpec(name: "item_details", description: "Подробности об элементе снимка по его ID.", parametersJSON: JSONText.string(from: itemDetails)),
            ToolSpec(name: "propose_plan", description: "Предложить пользователю план очистки. Ничего не удаляет: пользователь сам проверит список.", parametersJSON: JSONText.string(from: proposePlan)),
            ToolSpec(name: "lookup_knowledge", description: "Найти статью во встроенной справке SpotlessMac о процессах, папках, памяти, настройках macOS и организации файлов. Ничего не меняет.", parametersJSON: JSONText.string(from: lookupKnowledge)),
        ]
    }()

    static func parse(_ call: ToolCall) -> Result<AssistantTool, ToolParseError> {
        guard names.contains(call.name) else { return .failure(.unknownTool(call.name)) }
        guard let arguments = JSONText.object(from: call.argumentsJSON) as? [String: Any] else {
            return .failure(.invalidArguments("аргументы должны быть JSON-объектом"))
        }
        switch call.name {
        case "list_items":
            do throws(ToolParseError) {
                return .success(try parseListItems(arguments))
            } catch {
                return .failure(error)
            }
        case "item_details":
            guard let id = arguments["id"] as? String, !id.isEmpty else { return .failure(.invalidArguments("нужен id")) }
            return .success(.itemDetails(id: id))
        case "lookup_knowledge":
            do throws(ToolParseError) {
                return .success(try parseLookup(arguments))
            } catch {
                return .failure(error)
            }
        default:
            guard let proposal = PlanProposal.decode(json: call.argumentsJSON) else {
                return .failure(.invalidArguments("неверный формат плана"))
            }
            return .success(.proposePlan(proposal))
        }
    }

    // Strict on purpose: a filter the model asked for must never be silently dropped, otherwise it
    // would believe a narrowed list was returned. An explicit JSON null counts as "not provided".
    private static func parseListItems(_ arguments: [String: Any]) throws(ToolParseError) -> AssistantTool {
        var category: ScanCategory?
        if let value = provided(arguments["category"]) {
            guard let raw = value as? String else { throw .invalidArguments("category должно быть строкой") }
            guard let parsed = ScanCategory(rawValue: raw) else { throw .invalidArguments("неизвестная категория \(raw)") }
            category = parsed
        }
        let limit = try number("limit", in: arguments, allowNegative: true)
        let minBytes = try number("minBytes", in: arguments, allowNegative: false)
        let olderThanDays = try number("olderThanDays", in: arguments, allowNegative: false)
        return .listItems(
            category: category,
            minBytes: minBytes?.int64Value,
            olderThanDays: olderThanDays?.intValue,
            limit: min(max(limit?.intValue ?? 50, 1), 200)
        )
    }

    // Both fields are optional strings, but at least one must carry text; blank strings count as absent.
    private static func parseLookup(_ arguments: [String: Any]) throws(ToolParseError) -> AssistantTool {
        func text(_ key: String) throws(ToolParseError) -> String? {
            guard let value = provided(arguments[key]) else { return nil }
            guard let string = value as? String else { throw .invalidArguments("\(key) должно быть строкой") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let id = try text("id")
        let query = try text("query")
        guard id != nil || query != nil else { throw .invalidArguments("нужен id или query") }
        return .lookupKnowledge(id: id, query: query)
    }

    private static func provided(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    // JSON booleans are NSNumbers too, so they are rejected explicitly.
    private static func number(_ key: String, in arguments: [String: Any], allowNegative: Bool) throws(ToolParseError) -> NSNumber? {
        guard let value = provided(arguments[key]) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw .invalidArguments("\(key) должно быть числом")
        }
        if !allowNegative && number.doubleValue < 0 { throw .invalidArguments("\(key) не может быть отрицательным") }
        return number
    }
}
