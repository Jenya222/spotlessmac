import Foundation

struct AssistantMessage: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable { case streaming, complete, stopped, interrupted, failed }

    let id: UUID
    let role: Role
    var text: String
    var status: Status
    var plan: AssistantPlan?
    var planDismissed = false
    var planMalformed = false
    var errorText: String?
    var errorOpensSettings = false
    var model: String?
    var focus: AssistantFocus?
    var outboundSafeText: String?
    var outboundSafeFocus: AssistantFocus?
    var outboundAliasScope: UUID?
    let createdAt: Date

    static func user(_ text: String, at date: Date, focus: AssistantFocus? = nil) -> AssistantMessage {
        AssistantMessage(id: UUID(), role: .user, text: text, status: .complete, focus: focus, createdAt: date)
    }

    var displayText: String {
        guard let focus else { return text }
        return text + "\n\n" + focus.title + "\nПуть: " + focus.path + "\n" + focus.facts.joined(separator: "\n")
    }
}
