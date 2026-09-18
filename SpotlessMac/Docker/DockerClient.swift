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
    private let now: @Sendable () async -> Date

    init(
        run: @escaping RunDockerCommand = { try await DockerCommandRunner.run(arguments: $0) },
        now: @escaping @Sendable () async -> Date = { Date() }
    ) {
        self.run = run
        self.now = now
    }

    init(
        run: @escaping RunDockerCommand = { try await DockerCommandRunner.run(arguments: $0) },
        now: Date
    ) {
        self.run = run
        self.now = { now }
    }

    func scan() async throws -> DockerClientScanResult {
        let contextName = try await checked(["context", "show"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextName.isEmpty else {
            throw DockerCommandError.invalidOutput("Docker не сообщил текущий context.")
        }
        let context = try await inspectContext(named: contextName)

        let versionOutput = try await checked(in: context, ["version", "--format", "{{json .Server}}"])
        let serverVersion = parseServerVersion(versionOutput)

        let containerIDs = try await identifiers(
            from: checked(in: context, ["container", "ls", "--all", "--quiet", "--no-trunc"])
        )
        let containerJSON = try await inspectJSON(
            prefix: ["container", "inspect", "--size"],
            identifiers: containerIDs,
            context: context
        )

        let imageIDs = try await identifiers(
            from: checked(in: context, ["image", "ls", "--all", "--quiet", "--no-trunc"])
        )
        let imageJSON = try await inspectJSON(
            prefix: ["image", "inspect"],
            identifiers: imageIDs,
            context: context
        )

        let volumeNames = try await identifiers(
            from: checked(in: context, ["volume", "ls", "--filter", "dangling=true", "--quiet"])
        )
        let volumeJSON = try await inspectJSON(
            prefix: ["volume", "inspect"],
            identifiers: volumeNames,
            context: context
        )

        let buildCacheJSON: String
        var buildxBuilder: DockerBuildxIdentity?
        do {
            buildxBuilder = try await currentBuildxBuilder(in: context)
            if let buildxBuilder {
                buildCacheJSON = try await checked(in: context, [
                    "buildx", "du", "--builder", buildxBuilder.name, "--format", "json",
                ])
            } else {
                buildCacheJSON = ""
            }
        } catch {
            // Buildx is optional. Its absence must not hide core Docker results.
            buildxBuilder = nil
            buildCacheJSON = ""
        }

        let snapshot = try DockerScanParser.makeSnapshot(
            containerJSON: containerJSON,
            imageJSON: imageJSON,
            volumeJSON: volumeJSON,
            buildCacheJSON: buildCacheJSON,
            now: await now(),
            dockerContext: context,
            buildxBuilder: buildxBuilder
        )
        return DockerClientScanResult(serverVersion: serverVersion, snapshot: snapshot)
    }

    func delete(
        _ resources: [DockerResource],
        from snapshot: DockerScanSnapshot
    ) async -> [DockerDeletionFailure] {
        var failures: [DockerDeletionFailure] = []
        var confirmed: [DockerResource] = []
        for resource in resources {
            guard isConfirmed(resource, by: snapshot) else {
                failures.append(DockerDeletionFailure(
                    resource: resource,
                    reason: "Ресурс не подтверждён последним безопасным сканированием."
                ))
                continue
            }
            confirmed.append(resource)
        }
        guard !confirmed.isEmpty else { return failures }

        guard let expectedContext = snapshot.dockerContext else {
            return failures + confirmed.map {
                DockerDeletionFailure(resource: $0, reason: "Docker context не закреплён снимком проверки.")
            }
        }

        do {
            let currentContext = try await inspectContext(named: expectedContext.name)
            guard currentContext == expectedContext else {
                return failures + confirmed.map {
                    DockerDeletionFailure(
                        resource: $0,
                        reason: "Docker context изменился после проверки. Выполните сканирование снова."
                    )
                }
            }
        } catch {
            return failures + confirmed.map { DockerDeletionFailure(resource: $0, reason: error.localizedDescription) }
        }

        var builderIsValid = true
        if confirmed.contains(where: { $0.kind == .buildCache }) {
            do {
                guard let expectedBuilder = snapshot.buildxBuilder,
                      let currentBuilder = try await buildxBuilder(
                        named: expectedBuilder.name,
                        in: expectedContext
                      ),
                      currentBuilder == expectedBuilder else {
                    builderIsValid = false
                    throw DockerCommandError.invalidOutput(
                        "Buildx builder изменился после проверки. Выполните сканирование снова."
                    )
                }
            } catch {
                builderIsValid = false
                let cacheResources = confirmed.filter { $0.kind == .buildCache }
                failures += cacheResources.map {
                    DockerDeletionFailure(resource: $0, reason: error.localizedDescription)
                }
            }
        }

        for resource in confirmed where resource.kind != .buildCache || builderIsValid {
            guard let arguments = deletionArguments(for: resource, snapshot: snapshot) else { continue }
            do {
                let result = try await run(arguments)
                if result.exitCode != 0 {
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

    private func inspectContext(named name: String) async throws -> DockerContextIdentity {
        let output = try await checked([
            "context", "inspect", name, "--format", "{{json .Endpoints.docker.Host}}",
        ])
        guard let data = output.data(using: .utf8),
              let endpoint = try? JSONDecoder().decode(String.self, from: data),
              !endpoint.isEmpty else {
            throw DockerCommandError.invalidOutput("Docker context \(name) не содержит endpoint.")
        }
        return DockerContextIdentity(name: name, endpoint: endpoint)
    }

    private func checked(
        in context: DockerContextIdentity,
        _ arguments: [String]
    ) async throws -> String {
        try await checked(["--context", context.name] + arguments)
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

    private func inspectJSON(
        prefix: [String],
        identifiers: [String],
        context: DockerContextIdentity
    ) async throws -> Data {
        guard !identifiers.isEmpty else { return Data("[]".utf8) }
        return Data(try await checked(in: context, prefix + identifiers).utf8)
    }

    private func parseServerVersion(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["Version"] as? String
    }

    private func isConfirmed(
        _ resource: DockerResource,
        by snapshot: DockerScanSnapshot
    ) -> Bool {
        switch resource.kind {
        case .container:
            return snapshot.stoppedContainerIDs.contains(resource.id)
        case .image:
            let normalizedID = DockerScanParser.normalizeImageID(resource.id)
            return snapshot.unreferencedImageIDs.contains(normalizedID)
                && !snapshot.referencedImageIDs.contains(normalizedID)
        case .volume:
            return snapshot.danglingVolumeNames.contains(resource.id)
        case .buildCache:
            return snapshot.reclaimableBuildCacheIDs.contains(resource.id)
        }
    }

    private func deletionArguments(
        for resource: DockerResource,
        snapshot: DockerScanSnapshot
    ) -> [String]? {
        guard let context = snapshot.dockerContext else { return nil }
        let prefix = ["--context", context.name]
        switch resource.kind {
        case .container:
            return prefix + ["container", "rm", resource.id]
        case .image:
            return prefix + ["image", "rm", DockerScanParser.normalizeImageID(resource.id)]
        case .volume:
            return prefix + ["volume", "rm", resource.id]
        case .buildCache:
            guard let builder = snapshot.buildxBuilder else { return nil }
            let exactID = NSRegularExpression.escapedPattern(for: resource.id)
            return prefix + [
                "buildx", "prune", "--builder", builder.name, "--force",
                "--filter", "id=^\(exactID)$", "--filter", "until=168h",
            ]
        }
    }

    private func currentBuildxBuilder(
        in context: DockerContextIdentity
    ) async throws -> DockerBuildxIdentity? {
        let builders = try await buildxBuilders(in: context)
        return builders.first { $0.isCurrent }?.identity
    }

    private func buildxBuilder(
        named name: String,
        in context: DockerContextIdentity
    ) async throws -> DockerBuildxIdentity? {
        let builders = try await buildxBuilders(in: context)
        return builders.first { $0.identity.name == name }?.identity
    }

    private func buildxBuilders(
        in context: DockerContextIdentity
    ) async throws -> [BuildxListRecord] {
        let output = try await checked(in: context, ["buildx", "ls", "--format", "json"])
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(BuildxListRecord.self, from: Data($0.utf8))
        }
    }
}

private struct BuildxListRecord: Decodable {
    let current: Bool
    let driver: String
    let name: String
    let nodes: [BuildxNode]

    var isCurrent: Bool { current }

    var identity: DockerBuildxIdentity {
        DockerBuildxIdentity(
            name: name,
            driver: driver,
            nodeIdentities: Set(nodes.flatMap { node in
                node.ids.map { "\(node.name)|\(node.endpoint)|\($0)" }
            })
        )
    }

    enum CodingKeys: String, CodingKey {
        case current = "Current"
        case driver = "Driver"
        case name = "Name"
        case nodes = "Nodes"
    }
}

private struct BuildxNode: Decodable {
    let endpoint: String
    let ids: [String]
    let name: String

    enum CodingKeys: String, CodingKey {
        case endpoint = "Endpoint"
        case ids = "IDs"
        case name = "Name"
    }
}
