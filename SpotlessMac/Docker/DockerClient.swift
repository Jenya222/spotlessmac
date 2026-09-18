import Foundation

struct DockerClientScanResult: Sendable {
    let serverVersion: String?
    let snapshot: DockerScanSnapshot
}

struct DockerDeletionFailure: Sendable {
    let resource: DockerResource
    let reason: String
}

actor DockerClient {
    private let run: RunDockerCommand
    private let now: Date

    init(
        run: @escaping RunDockerCommand = { try await DockerCommandRunner.run(arguments: $0) },
        now: Date = Date()
    ) {
        self.run = run
        self.now = now
    }

    func scan() async throws -> DockerClientScanResult {
        let versionOutput = try await checked(["version", "--format", "{{json .Server}}"])
        let serverVersion = parseServerVersion(versionOutput)

        let containerIDs = try await identifiers(
            from: checked(["container", "ls", "--all", "--quiet", "--no-trunc"])
        )
        let containerJSON = try await inspectJSON(
            prefix: ["container", "inspect", "--size"],
            identifiers: containerIDs
        )

        let imageIDs = try await identifiers(
            from: checked(["image", "ls", "--all", "--quiet", "--no-trunc"])
        )
        let imageJSON = try await inspectJSON(
            prefix: ["image", "inspect"],
            identifiers: imageIDs
        )

        let volumeNames = try await identifiers(
            from: checked(["volume", "ls", "--filter", "dangling=true", "--quiet"])
        )
        let volumeJSON = try await inspectJSON(
            prefix: ["volume", "inspect"],
            identifiers: volumeNames
        )

        let buildCacheJSON: String
        do {
            buildCacheJSON = try await checked(["buildx", "du", "--format", "json"])
        } catch {
            // Buildx is optional. Its absence must not hide core Docker results.
            buildCacheJSON = ""
        }

        let snapshot = try DockerScanParser.makeSnapshot(
            containerJSON: containerJSON,
            imageJSON: imageJSON,
            volumeJSON: volumeJSON,
            buildCacheJSON: buildCacheJSON,
            now: now
        )
        return DockerClientScanResult(serverVersion: serverVersion, snapshot: snapshot)
    }

    func delete(
        _ resources: [DockerResource],
        from snapshot: DockerScanSnapshot
    ) async -> [DockerDeletionFailure] {
        var failures: [DockerDeletionFailure] = []
        for resource in resources {
            guard let arguments = deletionArguments(for: resource, snapshot: snapshot) else {
                failures.append(DockerDeletionFailure(
                    resource: resource,
                    reason: "Ресурс не подтверждён последним безопасным сканированием."
                ))
                continue
            }
            do {
                let result = try await run(arguments)
                if result.exitCode != 0 && !isAlreadyAbsent(result) {
                    failures.append(DockerDeletionFailure(
                        resource: resource,
                        reason: result.stderr.isEmpty ? "Docker не смог удалить ресурс." : result.stderr
                    ))
                }
            } catch {
                failures.append(DockerDeletionFailure(
                    resource: resource,
                    reason: error.localizedDescription
                ))
            }
        }
        return failures
    }

    private func checked(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.exitCode == 0 else {
            throw DockerCommandError.failed(
                arguments: arguments,
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        }
        return result.stdout
    }

    private func identifiers(from output: String) async throws -> [String] {
        var seen: Set<String> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private func inspectJSON(prefix: [String], identifiers: [String]) async throws -> Data {
        guard !identifiers.isEmpty else { return Data("[]".utf8) }
        return Data(try await checked(prefix + identifiers).utf8)
    }

    private func parseServerVersion(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["Version"] as? String
    }

    private func deletionArguments(
        for resource: DockerResource,
        snapshot: DockerScanSnapshot
    ) -> [String]? {
        switch resource.kind {
        case .container:
            guard snapshot.stoppedContainerIDs.contains(resource.id) else { return nil }
            return ["container", "rm", resource.id]
        case .image:
            let normalizedID = DockerScanParser.normalizeImageID(resource.id)
            guard snapshot.unreferencedImageIDs.contains(normalizedID),
                  !snapshot.referencedImageIDs.contains(normalizedID) else { return nil }
            return ["image", "rm", normalizedID]
        case .volume:
            guard snapshot.danglingVolumeNames.contains(resource.id) else { return nil }
            return ["volume", "rm", resource.id]
        case .buildCache:
            guard snapshot.reclaimableBuildCacheIDs.contains(resource.id) else { return nil }
            return ["buildx", "prune", "--force", "--filter", "id=\(resource.id)"]
        }
    }

    private func isAlreadyAbsent(_ result: DockerCommandResult) -> Bool {
        let message = "\(result.stdout)\n\(result.stderr)".lowercased()
        return message.contains("no such") || message.contains("not found")
    }
}

