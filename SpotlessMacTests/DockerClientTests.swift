import XCTest
@testable import SpotlessMac

final class DockerClientTests: XCTestCase {
    func testCommandRunnerDrainsLargeOutputWithoutBlocking() async throws {
        let result = try await DockerCommandRunner.run(
            executableURL: URL(filePath: "/usr/bin/perl"),
            arguments: ["-e", #"print "x" x 200_000"#]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 200_000)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testCommandRunnerTerminatesProcessWhenCancelled() async throws {
        let task = Task {
            try await DockerCommandRunner.run(
                executableURL: URL(filePath: "/usr/bin/yes"),
                arguments: []
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testScanUsesReadOnlyCommandsAndSkipsInspectForEmptyCollections() async throws {
        let recorder = DockerCommandRecorder(responses: [
            "context show": .success("desktop-linux\n"),
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux version --format {{json .Server}}": .success(#"{"Version":"29.4.1"}"#),
            "--context desktop-linux container ls --all --quiet --no-trunc": .success(""),
            "--context desktop-linux image ls --all --quiet --no-trunc": .success(""),
            "--context desktop-linux volume ls --filter dangling=true --quiet": .success(""),
            "--context desktop-linux buildx ls --format json": .success(buildxListJSON),
            "--context desktop-linux buildx du --builder desktop-linux --format json": .success(""),
        ])
        let client = DockerClient(
            run: { arguments in try await recorder.run(arguments) },
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let result = try await client.scan()
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(result.serverVersion, "29.4.1")
        XCTAssertTrue(result.snapshot.resources.isEmpty)
        XCTAssertEqual(result.snapshot.dockerContext, testContext)
        XCTAssertEqual(result.snapshot.buildxBuilder, testBuilder)
        XCTAssertEqual(calls, [
            ["context", "show"],
            ["context", "inspect", "desktop-linux", "--format", "{{json .Endpoints.docker.Host}}"],
            ["--context", "desktop-linux", "version", "--format", "{{json .Server}}"],
            ["--context", "desktop-linux", "container", "ls", "--all", "--quiet", "--no-trunc"],
            ["--context", "desktop-linux", "image", "ls", "--all", "--quiet", "--no-trunc"],
            ["--context", "desktop-linux", "volume", "ls", "--filter", "dangling=true", "--quiet"],
            ["--context", "desktop-linux", "buildx", "ls", "--format", "json"],
            ["--context", "desktop-linux", "buildx", "du", "--builder", "desktop-linux", "--format", "json"],
        ])
    }

    func testScanInspectsExactListedResourcesAndKeepsResultsWhenBuildxIsUnavailable() async throws {
        let recorder = DockerCommandRecorder(responses: [
            "context show": .success("desktop-linux"),
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux version --format {{json .Server}}": .success(#"{"Version":"29.4.1"}"#),
            "--context desktop-linux container ls --all --quiet --no-trunc": .success("container-one\n"),
            "--context desktop-linux container inspect --size container-one": .success(#"[{"Id":"container-one","Name":"/old","Image":"sha256:used","Created":"2026-01-01T00:00:00Z","State":{"Running":false,"Status":"exited","FinishedAt":"2026-01-02T00:00:00Z"},"SizeRw":10,"Config":{"Image":"used:latest"}}]"#),
            "--context desktop-linux image ls --all --quiet --no-trunc": .success("sha256:used\nsha256:free\nsha256:free\n"),
            "--context desktop-linux image inspect sha256:used sha256:free": .success(#"[{"Id":"sha256:used","RepoTags":["used:latest"],"Created":"2026-01-01T00:00:00Z","Size":20},{"Id":"sha256:free","RepoTags":["<none>:<none>"],"Created":"2026-01-01T00:00:00Z","Size":30}]"#),
            "--context desktop-linux volume ls --filter dangling=true --quiet": .success("unused-data\n"),
            "--context desktop-linux volume inspect unused-data": .success(#"[{"Name":"unused-data","CreatedAt":"2026-01-01T00:00:00Z","Labels":null}]"#),
            "--context desktop-linux buildx ls --format json": .success(buildxListJSON),
            "--context desktop-linux buildx du --builder desktop-linux --format json": DockerCommandResult(stdout: "", stderr: "buildx unavailable", exitCode: 1),
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
            ["context", "show"],
            ["context", "inspect", "desktop-linux", "--format", "{{json .Endpoints.docker.Host}}"],
            ["--context", "desktop-linux", "version", "--format", "{{json .Server}}"],
            ["--context", "desktop-linux", "container", "ls", "--all", "--quiet", "--no-trunc"],
            ["--context", "desktop-linux", "container", "inspect", "--size", "container-one"],
            ["--context", "desktop-linux", "image", "ls", "--all", "--quiet", "--no-trunc"],
            ["--context", "desktop-linux", "image", "inspect", "sha256:used", "sha256:free"],
            ["--context", "desktop-linux", "volume", "ls", "--filter", "dangling=true", "--quiet"],
            ["--context", "desktop-linux", "volume", "inspect", "unused-data"],
            ["--context", "desktop-linux", "buildx", "ls", "--format", "json"],
            ["--context", "desktop-linux", "buildx", "du", "--builder", "desktop-linux", "--format", "json"],
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
            reclaimableBuildCacheIDs: ["cache-id"],
            dockerContext: testContext,
            buildxBuilder: testBuilder
        )
        await recorder.setResponses([
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux buildx ls --format json": .success(buildxListJSON),
        ])
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete(resources, from: snapshot)
        let calls = await recorder.recordedCalls()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(calls, [
            ["context", "inspect", "desktop-linux", "--format", "{{json .Endpoints.docker.Host}}"],
            ["--context", "desktop-linux", "buildx", "ls", "--format", "json"],
            ["--context", "desktop-linux", "container", "rm", "container-id"],
            ["--context", "desktop-linux", "image", "rm", "sha256:image-id"],
            ["--context", "desktop-linux", "volume", "rm", "volume-name"],
            ["--context", "desktop-linux", "buildx", "prune", "--builder", "desktop-linux", "--force", "--filter", "id=^cache-id$", "--filter", "until=168h"],
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
            reclaimableBuildCacheIDs: [],
            dockerContext: testContext,
            buildxBuilder: testBuilder
        )
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete(resources, from: snapshot)
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(failures.map(\.resource.id), resources.map(\.id))
        XCTAssertTrue(calls.isEmpty)
    }

    func testDeleteRejectsChangedContextEndpointBeforeDestructiveCommand() async {
        let recorder = DockerCommandRecorder(responses: [
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///other.sock""#),
        ])
        let resource = deletionFixtures()[2]
        let snapshot = safeSnapshot(resources: [resource])
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete([resource], from: snapshot)
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(failures.map(\.resource.id), [resource.id])
        XCTAssertEqual(calls, [
            ["context", "inspect", "desktop-linux", "--format", "{{json .Endpoints.docker.Host}}"],
        ])
    }

    func testDeleteDoesNotSuppressGenericNotFoundErrors() async {
        let resource = deletionFixtures()[0]
        let recorder = DockerCommandRecorder(responses: [
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux container rm container-id": DockerCommandResult(
                stdout: "", stderr: "builder endpoint not found", exitCode: 1
            ),
        ])
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete([resource], from: safeSnapshot(resources: [resource]))

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.reason, "builder endpoint not found")
    }

    func testDeleteRejectsChangedBuildxBuilderBeforePrune() async {
        let resource = deletionFixtures()[3]
        let changedBuilder = #"{"Current":true,"Driver":"docker","Name":"desktop-linux","Nodes":[{"Endpoint":"desktop-linux","IDs":["different-worker"],"Name":"desktop-linux"}]}"#
        let recorder = DockerCommandRecorder(responses: [
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux buildx ls --format json": .success(changedBuilder),
        ])
        let client = DockerClient(run: { arguments in try await recorder.run(arguments) })

        let failures = await client.delete([resource], from: safeSnapshot(resources: [resource]))
        let calls = await recorder.recordedCalls()

        XCTAssertEqual(failures.map(\.resource.id), [resource.id])
        XCTAssertTrue(failures[0].reason.contains("builder изменился"))
        XCTAssertEqual(calls, [
            ["context", "inspect", "desktop-linux", "--format", "{{json .Endpoints.docker.Host}}"],
            ["--context", "desktop-linux", "buildx", "ls", "--format", "json"],
        ])
    }

    func testNowProviderIsReadForEveryScan() async throws {
        let clock = DockerClock([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 2_000),
        ])
        let recorder = DockerCommandRecorder(responses: [
            "context show": .success("desktop-linux"),
            "context inspect desktop-linux --format {{json .Endpoints.docker.Host}}": .success(#""unix:///docker.sock""#),
            "--context desktop-linux version --format {{json .Server}}": .success(#"{"Version":"29.4.1"}"#),
            "--context desktop-linux container ls --all --quiet --no-trunc": .success(""),
            "--context desktop-linux image ls --all --quiet --no-trunc": .success(""),
            "--context desktop-linux volume ls --filter dangling=true --quiet": .success(""),
            "--context desktop-linux buildx ls --format json": .success(buildxListJSON),
            "--context desktop-linux buildx du --builder desktop-linux --format json": .success(""),
        ])
        let client = DockerClient(
            run: { arguments in try await recorder.run(arguments) },
            now: { await clock.next() }
        )

        _ = try await client.scan()
        _ = try await client.scan()
        let remainingDates = await clock.remainingCount()

        XCTAssertEqual(remainingDates, 0)
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

    private func safeSnapshot(resources: [DockerResource]) -> DockerScanSnapshot {
        DockerScanSnapshot(
            resources: resources,
            referencedImageIDs: [],
            stoppedContainerIDs: Set(resources.filter { $0.kind == .container }.map(\.id)),
            unreferencedImageIDs: Set(resources.filter { $0.kind == .image }.map { DockerScanParser.normalizeImageID($0.id) }),
            danglingVolumeNames: Set(resources.filter { $0.kind == .volume }.map(\.id)),
            reclaimableBuildCacheIDs: Set(resources.filter { $0.kind == .buildCache }.map(\.id)),
            dockerContext: testContext,
            buildxBuilder: testBuilder
        )
    }
}

private actor DockerCommandRecorder {
    private var responses: [String: DockerCommandResult]
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

    func setResponses(_ additions: [String: DockerCommandResult]) {
        responses.merge(additions) { _, new in new }
    }
}

private actor DockerClock {
    private var dates: [Date]

    init(_ dates: [Date]) { self.dates = dates }

    func next() -> Date { dates.removeFirst() }
    func remainingCount() -> Int { dates.count }
}

private let testContext = DockerContextIdentity(name: "desktop-linux", endpoint: "unix:///docker.sock")
private let testBuilder = DockerBuildxIdentity(
    name: "desktop-linux",
    driver: "docker",
    nodeIdentities: ["desktop-linux|desktop-linux|worker-id"]
)
private let buildxListJSON = #"{"Current":true,"Driver":"docker","Name":"desktop-linux","Nodes":[{"Endpoint":"desktop-linux","IDs":["worker-id"],"Name":"desktop-linux"}]}"#

private extension DockerCommandResult {
    static func success(_ stdout: String) -> DockerCommandResult {
        DockerCommandResult(stdout: stdout, stderr: "", exitCode: 0)
    }
}
