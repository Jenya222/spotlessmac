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

    init(path: URL, size: Int64, location: String, confidence: MatchConfidence, isSelected: Bool) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.location = location
        self.confidence = confidence
        self.isSelected = isSelected
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
