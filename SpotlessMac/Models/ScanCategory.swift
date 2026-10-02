import Foundation

enum ScanCategory: String, CaseIterable, Identifiable, Sendable {
    case userCaches = "user_caches"
    case developerCaches = "developer_caches"
    case logs = "logs"
    case trash = "trash"
    case largeFiles = "large_files"
    case oldInstallers = "old_installers"

    case modelCaches = "model_caches"
    case knownAppCaches = "known_app_caches"
    case projectArtifacts = "project_artifacts"
    case recordings = "recordings"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelCaches: "Модели Hugging Face"
        case .knownAppCaches: "Кэши Cursor, Claude и инструментов"
        case .projectArtifacts: "Зависимости и сборки проектов"
        case .recordings: "Личные записи"
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
        case .trash, .largeFiles, .oldInstallers, .modelCaches, .knownAppCaches, .projectArtifacts, .recordings:
            false
        }
    }

    var cleanupReason: String {
        switch self {
        case .modelCaches: "Потребуется повторная загрузка модели или датасета."
        case .knownAppCaches: "Известный кэш. Закройте программу перед очисткой."
        case .projectArtifacts: "Потребуется переустановка зависимостей или пересборка."
        case .recordings: "Личные записи — прослушайте перед удалением."
        case .userCaches: "Временные данные приложений создаются заново при необходимости."
        case .developerCaches: "Данные сборки и кеши инструментов разработчика можно восстановить."
        case .logs: "Диагностические журналы больше не нужны для обычной работы."
        case .trash: "Файлы уже находятся в Корзине."
        case .largeFiles: "Крупный пользовательский файл — проверьте содержимое перед удалением."
        case .oldInstallers: "Старый установщик из Downloads обычно не нужен после установки."
        }
    }
}
