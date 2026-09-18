import Foundation

enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "user_caches"
    case developerCaches = "developer_caches"
    case logs = "logs"
    case trash = "trash"
    case largeFiles = "large_files"
    case oldInstallers = "old_installers"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userCaches: "Пользовательские кеши"
        case .developerCaches: "Dev-кеши"
        case .logs: "Логи"
        case .trash: "Корзина"
        case .largeFiles: "Крупные файлы"
        case .oldInstallers: "Старые установщики"
        }
    }

    var isBatchCleanable: Bool {
        switch self {
        case .userCaches, .developerCaches, .logs:
            true
        case .trash, .largeFiles, .oldInstallers:
            false
        }
    }

    var cleanupReason: String {
        switch self {
        case .userCaches: "Временные данные приложений создаются заново при необходимости."
        case .developerCaches: "Данные сборки и кеши инструментов разработчика можно восстановить."
        case .logs: "Диагностические журналы больше не нужны для обычной работы."
        case .trash: "Файлы уже находятся в Корзине."
        case .largeFiles: "Крупный пользовательский файл — проверьте содержимое перед удалением."
        case .oldInstallers: "Старый установщик из Downloads обычно не нужен после установки."
        }
    }
}
