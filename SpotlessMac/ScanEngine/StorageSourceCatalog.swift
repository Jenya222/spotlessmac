import Foundation

struct StorageSource: Identifiable, Sendable {
    let url: URL
    let title: String
    let explanation: String
    var id: String { url.path(percentEncoded: false) }
}

enum StorageSourceCatalog {
    static func sources(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [StorageSource] {
        let relative: [(String, String, String)] = [
            ("Applications", "Программы пользователя", "Установленные программы; их данные показаны отдельно."),
            ("Library/Application Support", "Данные приложений", "Здесь могут находиться документы, базы, истории и виртуальные машины. Большой размер не означает мусор."),
            ("Library/Containers", "Контейнеры приложений и Docker", "Docker очищается через отдельный раздел. Виртуальный диск целиком не удаляется."),
            ("Library/Group Containers", "Общие данные приложений", "Эти данные могут использоваться несколькими программами."),
            ("Library/Developer", "Xcode и симуляторы", "Кэши, данные устройств и симуляторы имеют разные правила очистки."),
            ("Library/Caches", "Кэши приложений", "Восстанавливаемые данные; перед очисткой закройте соответствующую программу."),
            ("Library/Logs", "Журналы", "Диагностические журналы приложений."),
            (".cache", "Кэши инструментов и AI-моделей", "Модели Hugging Face могут потребовать повторной загрузки."),
            (".npm/_cacache", "Кэш npm", "Исходники и настройки npm не входят в этот источник."),
            (".ollama/models", "Модели Ollama", "Только просмотр. Управляйте моделями через Ollama."),
            ("MyProjects", "Проекты", "Исходники сохраняются; зависимости и сборки предлагаются для ручной проверки."),
            ("Documents", "Документы", "Личные файлы — проверяйте перед удалением."),
            ("Downloads", "Загрузки", "Установщики и загруженные файлы."),
            ("Desktop", "Рабочий стол", "Личные файлы."),
            ("Movies", "Видео", "Личные видеофайлы."),
            ("Music", "Музыка", "Личные файлы и библиотеки."),
            ("Pictures", "Изображения", "Фотобиблиотеки открывайте в соответствующем приложении.")
        ]
        let defaults = [StorageSource(url: URL(filePath: "/Applications"), title: "Программы", explanation: "Размер программ без их пользовательских данных.")]
            + relative.map { StorageSource(url: home.appending(path: $0.0), title: $0.1, explanation: $0.2) }
        let extras = StorageRootRegistry.roots(kind: .projects).map { StorageSource(url: $0, title: "Выбранная папка проектов", explanation: "Исходники сохраняются. Для очистки предлагаются только проверенные зависимости и сборки.") }
            + StorageRootRegistry.roots(kind: .huggingFace).map { StorageSource(url: $0, title: "Выбранный кэш Hugging Face", explanation: "Удаление целого репозитория потребует повторной загрузки.") }
        // A nested shortcut must not be counted twice with its parent source.
        return nonOverlapping(defaults + extras)

    }
    static func nonOverlapping(_ sources: [StorageSource]) -> [StorageSource] {
        var accepted: [StorageSource] = []
        for source in sources.sorted(by: { PathPolicy.canonical($0.url).count < PathPolicy.canonical($1.url).count }) {
            if !accepted.contains(where: { PathPolicy.contains(PathPolicy.canonical(source.url), in: PathPolicy.canonical($0.url)) }) {
                accepted.append(source)
            }
        }
        let ids = Set(accepted.map(\.id))
        var emitted = Set<String>()
        return sources.filter { ids.contains($0.id) && emitted.insert($0.id).inserted }
    }
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] { sources(home: home).map(\.url) }
    static var policy: PathPolicy {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let explicit = StorageRootRegistry.roots(kind: .projects) + StorageRootRegistry.roots(kind: .huggingFace)
        return PathPolicy(readRoots: roots().filter { root in
            if explicit.contains(where: { PathPolicy.canonical($0) == PathPolicy.canonical(root) }) { return true }
            return root.path == "/Applications" || PathPolicy.isUnredirected(root, below: home)
        })
    }
}
