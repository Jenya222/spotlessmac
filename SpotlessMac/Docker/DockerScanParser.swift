import Foundation

enum DockerScanParser {
    static func makeSnapshot(
        containerJSON: Data,
        imageJSON: Data,
        volumeJSON: Data,
        buildCacheJSON: String,
        now: Date,
        minimumCacheAge: TimeInterval = 7 * 86_400
    ) throws -> DockerScanSnapshot {
        let decoder = JSONDecoder()
        let containers = try decoder.decode([ContainerInspect].self, from: containerJSON)
        let images = try decoder.decode([ImageInspect].self, from: imageJSON)
        let volumes = try decoder.decode([VolumeInspect].self, from: volumeJSON)

        let referencedImageIDs = Set(containers.map { normalizeImageID($0.image) })
        let stoppedContainerIDs = Set(containers.filter { !$0.state.running }.map(\.id))
        var unreferencedImageIDs: Set<String> = []
        var resources: [DockerResource] = []

        for container in containers where !container.state.running {
            resources.append(DockerResource(
                id: container.id,
                kind: .container,
                name: container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                detail: "Остановлен · образ \(container.config?.image ?? shortID(container.image))",
                size: container.sizeRw,
                createdAt: parseDate(container.created),
                lastUsedAt: parseDate(container.state.finishedAt),
                risk: .review,
                isSelected: false
            ))
        }

        for image in images {
            let normalizedID = normalizeImageID(image.id)
            guard !referencedImageIDs.contains(normalizedID) else { continue }
            unreferencedImageIDs.insert(normalizedID)
            let tags = (image.repoTags ?? []).filter { $0 != "<none>:<none>" }
            let isDangling = tags.isEmpty
            resources.append(DockerResource(
                id: normalizedID,
                kind: .image,
                name: isDangling ? "Без тега · \(shortID(normalizedID))" : tags.joined(separator: ", "),
                detail: isDangling
                    ? "Dangling image не используется контейнерами."
                    : "Образ не используется ни одним контейнером.",
                size: image.size,
                createdAt: parseDate(image.created),
                lastUsedAt: nil,
                risk: isDangling ? .rebuildable : .review,
                isSelected: isDangling
            ))
        }

        let danglingVolumeNames = Set(volumes.map(\.name))
        for volume in volumes {
            let labelText = volume.labels?.isEmpty == false
                ? volume.labels!.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                : "Нет меток"
            resources.append(DockerResource(
                id: volume.name,
                kind: .volume,
                name: volume.name,
                detail: "Данные volume могут быть невосстановимы · \(labelText)",
                size: nil,
                createdAt: parseDate(volume.createdAt),
                lastUsedAt: nil,
                risk: .dataLoss,
                isSelected: false
            ))
        }

        var reclaimableCacheIDs: Set<String> = []
        for record in parseBuildCache(buildCacheJSON) {
            guard record.reclaimable,
                  let lastAccessedAt = parseDate(record.lastAccessedAt),
                  now.timeIntervalSince(lastAccessedAt) >= minimumCacheAge else { continue }
            reclaimableCacheIDs.insert(record.id)
            resources.append(DockerResource(
                id: record.id,
                kind: .buildCache,
                name: record.description?.isEmpty == false ? record.description! : "Build cache · \(shortID(record.id))",
                detail: "Восстанавливаемый кеш сборки не использовался больше 7 дней.",
                size: ByteSizeParser.parse(record.size),
                createdAt: nil,
                lastUsedAt: lastAccessedAt,
                risk: .rebuildable,
                isSelected: true
            ))
        }

        resources.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.isSelected != $1.isSelected { return $0.isSelected }
            return ($0.size ?? -1) > ($1.size ?? -1)
        }

        return DockerScanSnapshot(
            resources: resources,
            referencedImageIDs: referencedImageIDs,
            stoppedContainerIDs: stoppedContainerIDs,
            unreferencedImageIDs: unreferencedImageIDs,
            danglingVolumeNames: danglingVolumeNames,
            reclaimableBuildCacheIDs: reclaimableCacheIDs
        )
    }

    static func normalizeImageID(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("sha256:") ? normalized : "sha256:\(normalized)"
    }

    private static func parseBuildCache(_ output: String) -> [BuildCacheRecord] {
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(BuildCacheRecord.self, from: Data(line.utf8))
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func shortID(_ value: String) -> String {
        String(value.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
}

private struct ContainerInspect: Decodable {
    let id: String
    let name: String
    let image: String
    let created: String?
    let state: ContainerState
    let sizeRw: Int64?
    let config: ContainerConfig?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case image = "Image"
        case created = "Created"
        case state = "State"
        case sizeRw = "SizeRw"
        case config = "Config"
    }
}

private struct ContainerState: Decodable {
    let running: Bool
    let status: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case running = "Running"
        case status = "Status"
        case finishedAt = "FinishedAt"
    }
}

private struct ContainerConfig: Decodable {
    let image: String?

    enum CodingKeys: String, CodingKey { case image = "Image" }
}

private struct ImageInspect: Decodable {
    let id: String
    let repoTags: [String]?
    let created: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case created = "Created"
        case size = "Size"
    }
}

private struct VolumeInspect: Decodable {
    let name: String
    let createdAt: String?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case createdAt = "CreatedAt"
        case labels = "Labels"
    }
}

private struct BuildCacheRecord: Decodable {
    let id: String
    let reclaimable: Bool
    let size: String
    let lastAccessedAt: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case reclaimable = "Reclaimable"
        case size = "Size"
        case lastAccessedAt = "LastAccessedAt"
        case description = "Description"
    }
}

enum ByteSizeParser {
    static func parse(_ value: String) -> Int64? {
        let cleaned = value
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard let split = cleaned.firstIndex(where: { !$0.isNumber && $0 != "." && $0 != "," }) else {
            return Int64(cleaned)
        }
        let numberText = cleaned[..<split].replacingOccurrences(of: ",", with: ".")
        let unit = String(cleaned[split...])
        guard let number = Double(numberText) else { return nil }
        let multipliers: [String: Double] = [
            "B": 1,
            "KB": 1_000,
            "MB": 1_000_000,
            "GB": 1_000_000_000,
            "TB": 1_000_000_000_000,
            "KIB": 1_024,
            "MIB": 1_048_576,
            "GIB": 1_073_741_824,
            "TIB": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64(number * multiplier)
    }
}
