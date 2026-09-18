import Foundation

enum StorageRecoverySort: String, CaseIterable, Identifiable {
    case sizeDescending
    case newest
    case oldest
    case name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sizeDescending: "По размеру"
        case .newest: "Сначала новые"
        case .oldest: "Сначала старые"
        case .name: "По имени"
        }
    }
}

enum StorageRecoveryQuery {
    static func filter(
        _ items: [ScanItem],
        searchText: String,
        sort: StorageRecoverySort
    ) -> [ScanItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = needle.isEmpty ? items : items.filter {
            $0.path.lastPathComponent.localizedCaseInsensitiveContains(needle)
                || $0.path.path(percentEncoded: false).localizedCaseInsensitiveContains(needle)
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .sizeDescending:
                lhs.size > rhs.size
            case .newest:
                (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            case .oldest:
                (lhs.modifiedAt ?? .distantFuture) < (rhs.modifiedAt ?? .distantFuture)
            case .name:
                lhs.path.lastPathComponent.localizedStandardCompare(rhs.path.lastPathComponent) == .orderedAscending
            }
        }
    }
}
