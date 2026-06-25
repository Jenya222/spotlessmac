import Foundation

enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "user_caches"
    case developerCaches = "developer_caches"
    case logs = "logs"
    case trash = "trash"
    case largeFiles = "large_files"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userCaches: "Пользовательские кеши"
        case .developerCaches: "Dev-кеши"
        case .logs: "Логи"
        case .trash: "Корзина"
        case .largeFiles: "Крупные файлы"
        }
    }
}
