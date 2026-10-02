import Foundation

enum CleanupDisposition: Sendable, Hashable {
    case rebuildable, redownload, personalData, inspectOnly
    var label: String {
        switch self {
        case .rebuildable: "Создаётся заново"
        case .redownload: "Потребуется повторная загрузка"
        case .personalData: "Личные данные"
        case .inspectOnly: "Только просмотр"
        }
    }
}
struct CleanupPolicy: Sendable, Hashable {
    let disposition: CleanupDisposition
    let reason: String
    let requiresClosedOwner: Bool
    var canDelete: Bool { disposition != .inspectOnly }
}

enum OwnerActivity: Sendable { case closed, running, unknown }
