import Foundation

// How a leftover was matched to the app.
enum MatchConfidence: Sendable {
    case exact      // matched by bundle identifier (or the .app itself)
    case nameOnly   // matched only by display name — "возможно связано"
}

// A single file/directory slated for removal during uninstall: either the
// .app bundle itself or one of its leftover files.
struct LeftoverItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let location: String          // human label, e.g. "Программа", "Caches"
    let confidence: MatchConfidence
    var isSelected: Bool
    let identity: StorageFileIdentity?
    var isCache: Bool { ["Caches", "Logs", "Кэш приложения"].contains(location) }
    var dispositionLabel: String { isCache ? "Восстанавливаемый кэш" : location == "Программа" ? "Программа" : "Личные данные/настройки" }

    init(path: URL, size: Int64, location: String, confidence: MatchConfidence, isSelected: Bool) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.location = location
        self.confidence = confidence
        self.isSelected = isSelected
        self.identity = StorageFileIdentity.read(path)
    }

    static func nonOverlapping(_ items: [LeftoverItem]) -> [LeftoverItem] {
        var result: [LeftoverItem] = []
        for item in items.sorted(by: { PathPolicy.canonical($0.path).count < PathPolicy.canonical($1.path).count }) {
            if !result.contains(where: { PathPolicy.contains(PathPolicy.canonical(item.path), in: PathPolicy.canonical($0.path)) }) { result.append(item) }
        }
        return result
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
