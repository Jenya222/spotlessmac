import XCTest
@testable import SpotlessMac

final class DockerClientTests: XCTestCase {
    func testScanUsesReadOnlyCommandsAndSkipsInspectForEmptyCollections() async throws {
        let recorder = DockerCommandRecorder(responses: [
            "version --format {{json .Server}}": .success(#"{"Version":"29.4.1"}"#),
            "container ls --all --quiet --no-trunc": .success(""),
            "image ls --all --quiet --no-trunc": .success(""),
            "volume ls --filter dangling=true --quiet": .success(""),
            "buildx du --format json": .success(""),
        ])
        let client = DockerClient(
            run: { arguments in try await recorder.run(arguments) },
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let result = try await client.scan()
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(result.serverVersion, "29.4.1")
        XCTAssertTrue(result.snapshot.resources.isEmpty)
        XCTAssertEqual(calls, [
            ["version", "--format", "{{json .Server}}"],
            ["container", "ls", "--all", "--quiet", "--no-trunc"],
            ["image", "ls", "--all", "--quiet", "--no-trunc"],
            ["volume", "ls", "--filter", "dangling=true", "--quiet"],
            ["buildx", "du", "--format", "json"],
        ])
    }

    func testScanInspectsExactListedResourcesAndKeepsResultsWhenBuildxIsUnavailable() async throws {
        let recorder = DockerCommandRecorder(responses: [
            "version --format {{json .Server}}": .success(#"{"Version":"29.4.1"}"#),
            "container ls --all --quiet --no-trunc": .success("container-one\n"),
            "container inspect --size container-one": .success(#"[{"Id":"container-one","Name":"/old","Image":"sha256:used","Created":"2026-01-01T00:00:00Z","State":{"Running":false,"Status":"exited","FinishedAt":"2026-01-02T00:00:00Z"},"SizeRw":10,"Config":{"Image":"used:latest"}}]"#),
            "image ls --all --quiet --no-trunc": .success("sha256:used\nsha256:free\nsha256:free\n"),
            "image inspect sha256:used sha256:free": .success(#"[{"Id":"sha256:used","RepoTags":["used:latest"],"Created":"2026-01-01T00:00:00Z","Size":20},{"Id":"sha256:free","RepoTags":["<none>:<none>"],"Created":"2026-01-01T00:00:00Z","Size":30}]"#),
            "volume ls --filter dangling=true --quiet": .success("unused-data\n"),
            "volume inspect unused-data": .success(#"[{"Name":"unused-data","CreatedAt":"2026-01-01T00:00:00Z","Labels":null}]"#),
            "buildx du --format json": DockerCommandResult(stdout: "", stderr: "buildx unavailable", exitCode: 1),
        ])
        let client = DockerClient(
            run: { arguments in try await recorder.run(arguments) },
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let result = try await client.scan()
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(result.snapshot.resources.map(\.id), [
            "sha256:free", "container-one", "unused-data",
        ])
        XCTAssertEqual(calls, [
            ["version", "--format", "{{json .Server}}"],
            ["container", "ls", "--all", "--quiet", "--no-trunc"],
            ["container", "inspect", "--size", "container-one"],
            ["image", "ls", "--all", "--quiet", "--no-trunc"],
            ["image", "inspect", "sha256:used", "sha256:free"],
            ["volume", "ls", "--filter", "dangling=true", "--quiet"],
            ["volume", "inspect", "unused-data"],
            ["buildx", "du", "--format", "json"],
        ])
    }

    func testDeleteBuildsOnlyExactResourceCommands() async throws {
        let recorder = DockerCommandRecorder(defaultResult: .success("removed"))
        let resources = deletionFixtures()
        let snapshot = DockerScanSnapshot(
            resources: resources,
            referencedImageIDs: [],
            stoppedContainerIDs: ["container-id"],
            unreferencedImageIDs: ["sha256:image-id"],
            danglingVolumeNames: ["volume-name"],
            reclaimableBuildCacheIDs: ["cache-id"]
        )
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete(resources, from: snapshot)
        let calls = await recorder.recordedCalls()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(calls, [
            ["container", "rm", "container-id"],
            ["image", "rm", "sha256:image-id"],
            ["volume", "rm", "volume-name"],
            ["buildx", "prune", "--force", "--filter", "id=cache-id"],
        ])
    }

    func testDeleteRejectsResourcesWithoutScanEvidenceBeforeRunningCommands() async {
        let recorder = DockerCommandRecorder(defaultResult: .success("should not run"))
        let resources = deletionFixtures()
        let snapshot = DockerScanSnapshot(
            resources: resources,
            referencedImageIDs: ["sha256:image-id"],
            stoppedContainerIDs: [],
            unreferencedImageIDs: [],
            danglingVolumeNames: [],
            reclaimableBuildCacheIDs: []
        )
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete(resources, from: snapshot)
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(failures.map(\.resource.id), resources.map(\.id))
        XCTAssertTrue(calls.isEmpty)
    }

    private func deletionFixtures() -> [DockerResource] {
        [
            DockerResource(
                id: "container-id", kind: .container, name: "old", detail: "",
                size: 1, createdAt: nil, lastUsedAt: nil, risk: .review, isSelected: true
            ),
            DockerResource(
                id: "sha256:image-id", kind: .image, name: "old:tag", detail: "",
                size: 2, createdAt: nil, lastUsedAt: nil, risk: .review, isSelected: true
            ),
            DockerResource(
                id: "volume-name", kind: .volume, name: "volume-name", detail: "",
                size: nil, createdAt: nil, lastUsedAt: nil, risk: .dataLoss, isSelected: true
            ),
            DockerResource(
                id: "cache-id", kind: .buildCache, name: "cache", detail: "",
                size: 3, createdAt: nil, lastUsedAt: nil, risk: .rebuildable, isSelected: true
            ),
        ]
    }
}

private actor DockerCommandRecorder {
    private let responses: [String: DockerCommandResult]
    private let defaultResult: DockerCommandResult?
    private var calls: [[String]] = []

    init(responses: [String: DockerCommandResult] = [:], defaultResult: DockerCommandResult? = nil) {
        self.responses = responses
        self.defaultResult = defaultResult
    }

    func run(_ arguments: [String]) throws -> DockerCommandResult {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        if let response = responses[key] { return response }
        if let defaultResult { return defaultResult }
        throw DockerCommandError.failed(arguments: arguments, stderr: "Unexpected command: \(key)", exitCode: 127)
    }

    func recordedCalls() -> [[String]] { calls }
}

private extension DockerCommandResult {
    static func success(_ stdout: String) -> DockerCommandResult {
        DockerCommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}
