import Foundation

struct PlanFilter: Codable, Equatable, Sendable {
    var category: String?
    var olderThanDays: Int?
    var minBytes: Int64?
}

struct PlanProposal: Codable, Equatable, Sendable {
    var items: [String]
    var filters: [PlanFilter]
    var reason: String

    init(items: [String] = [], filters: [PlanFilter] = [], reason: String = "") {
        self.items = items
        self.filters = filters
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([String].self, forKey: .items) ?? []
        filters = try container.decodeIfPresent([PlanFilter].self, forKey: .filters) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    static func decode(json: String) -> PlanProposal? {
        try? JSONDecoder().decode(PlanProposal.self, from: Data(json.utf8))
    }
}

struct SkippedGroup: Codable, Equatable, Sendable {
    let label: String
    let count: Int
}

struct AssistantPlan: Codable, Equatable, Sendable {
    let itemIDs: [UUID]
    let totalBytes: Int64
    let reason: String
    let skipped: [SkippedGroup]
    let manualReview: [String]

    var isEmpty: Bool { itemIDs.isEmpty }
    var isMeaningful: Bool { !itemIDs.isEmpty || !skipped.isEmpty || !manualReview.isEmpty }
}

// Turns a model proposal into a selection of existing snapshot items.
// Only batch-cleanable, deletable, non-personal items are ever selected.
enum PlanResolver {
    static let maxManualReviewLines = 10

    static func resolve(_ proposal: PlanProposal, in snapshot: SystemSnapshot) -> AssistantPlan {
        var candidates: [SnapshotItem] = []
        var seen: Set<String> = []
        var unknown = 0

        for shortID in proposal.items {
            guard let item = snapshot.item(shortID: shortID) else { unknown += 1; continue }
            if seen.insert(item.shortID).inserted { candidates.append(item) }
        }
        for filter in proposal.filters {
            guard let raw = filter.category, let category = ScanCategory(rawValue: raw) else { continue }
            let cutoff = filter.olderThanDays.map { snapshot.takenAt.addingTimeInterval(-Double($0) * 86_400) }
            for item in snapshot.items where item.category == category {
                if let minBytes = filter.minBytes, item.bytes < minBytes { continue }
                if let cutoff {
                    guard let modified = item.modifiedAt, modified < cutoff else { continue }
                }
                if seen.insert(item.shortID).inserted { candidates.append(item) }
            }
        }

        var selected: [SnapshotItem] = []
        var manual: [SnapshotItem] = []
        var personal = 0
        var inspectOnly = 0
        for item in candidates {
            switch item.disposition {
            case .personalData: personal += 1
            case .inspectOnly: inspectOnly += 1
            case .rebuildable, .redownload:
                if item.isBatchCleanable { selected.append(item) } else { manual.append(item) }
            }
        }

        var skipped: [SkippedGroup] = []
        if unknown > 0 { skipped.append(SkippedGroup(label: "неизвестные ID", count: unknown)) }
        if personal > 0 { skipped.append(SkippedGroup(label: "личные данные", count: personal)) }
        if inspectOnly > 0 { skipped.append(SkippedGroup(label: "только просмотр", count: inspectOnly)) }
        if !manual.isEmpty { skipped.append(SkippedGroup(label: "удаляются вручную по одному", count: manual.count)) }

        return AssistantPlan(
            itemIDs: selected.map(\.itemID),
            totalBytes: selected.reduce(0) { $0 + $1.bytes },
            reason: proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines),
            skipped: skipped,
            manualReview: manual.prefix(maxManualReviewLines).map {
                "\(URL(filePath: $0.path).lastPathComponent) · \(SnapshotRenderer.bytes($0.bytes))"
            }
        )
    }
}
