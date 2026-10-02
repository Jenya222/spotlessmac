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
    let createdAt: Date

    static func user(_ text: String, at date: Date) -> AssistantMessage {
        AssistantMessage(id: UUID(), role: .user, text: text, status: .complete, createdAt: date)
    }
}
