import Foundation
import Observation

struct DockerCleanupSelection: Sendable {
    let resources: [DockerResource]
    let scanSnapshot: DockerScanSnapshot

    var containsVolumes: Bool {
        resources.contains { $0.kind == .volume }
    }
}

enum DockerCleanupResult: Sendable {
    case completed(successCount: Int)
    case busy
    case licenseRequired
    case volumeAcknowledgmentRequired
}

@Observable
@MainActor
final class DockerCleanupViewModel {
    typealias ScanDocker = @Sendable () async throws -> DockerClientScanResult
    typealias DeleteDocker = @Sendable ([DockerResource], DockerScanSnapshot) async -> [DockerDeletionFailure]

    var availability: DockerAvailability = .checking
    var resources: [DockerResource] = []
    var isScanning = false
    var isDeleting = false
    var failures: [DockerDeletionFailure] = []

    private let scanDocker: ScanDocker
    private let deleteDocker: DeleteDocker
    private var latestSnapshot: DockerScanSnapshot?

    init(
        client: DockerClient = DockerClient(),
        scanDocker: ScanDocker? = nil,
        deleteDocker: DeleteDocker? = nil
    ) {
        self.scanDocker = scanDocker ?? { try await client.scan() }
        self.deleteDocker = deleteDocker ?? { resources, snapshot in
            await client.delete(resources, from: snapshot)
        }
    }

    var selectedResources: [DockerResource] {
        resources.filter(\.isSelected)
    }

    var selectedKnownBytes: Int64 {
        selectedResources.compactMap(\.size).reduce(0, +)
    }

    var totalKnownBytes: Int64 {
        resources.compactMap(\.size).reduce(0, +)
    }

    @discardableResult
    func scan() async -> Bool {
        guard !isScanning, !isDeleting else { return false }
        isScanning = true
        availability = .checking
        defer { isScanning = false }
        await loadScan()
        return true
    }

    func toggle(_ resource: DockerResource) {
        guard !isScanning, !isDeleting,
              let index = resources.firstIndex(where: { $0.id == resource.id && $0.kind == resource.kind }) else {
            return
        }
        resources[index].isSelected.toggle()
    }

    func makeCleanupSnapshot() -> DockerCleanupSelection? {
        let selected = selectedResources
        guard !selected.isEmpty, let latestSnapshot else { return nil }
        return DockerCleanupSelection(resources: selected, scanSnapshot: latestSnapshot)
    }

    func deleteConfirmed(
        _ selection: DockerCleanupSelection,
        volumeAcknowledged: Bool,
        canClean: Bool,
        recordSuccessfulClean: @escaping @MainActor () -> Void
    ) async -> DockerCleanupResult {
        guard !isScanning, !isDeleting else { return .busy }
        guard canClean else { return .licenseRequired }
        guard !selection.containsVolumes || volumeAcknowledged else {
            return .volumeAcknowledgmentRequired
        }

        isDeleting = true
        failures = []
        defer { isDeleting = false }

        let deletionFailures = await deleteDocker(selection.resources, selection.scanSnapshot)
        failures = deletionFailures
        let successCount = max(0, selection.resources.count - deletionFailures.count)
        if successCount > 0 {
            recordSuccessfulClean()
        }
        await loadScan()
        return .completed(successCount: successCount)
    }

    private func loadScan() async {
        do {
            let result = try await scanDocker()
            latestSnapshot = result.snapshot
            resources = result.snapshot.resources
            availability = .ready(serverVersion: result.serverVersion)
        } catch DockerCommandError.executableNotFound {
            latestSnapshot = nil
            resources = []
            availability = .cliMissing
        } catch DockerCommandError.failed(_, let stderr, _) {
            latestSnapshot = nil
            resources = []
            availability = .daemonUnavailable(
                message: stderr.isEmpty ? "Docker Desktop не отвечает." : stderr
            )
        } catch {
            latestSnapshot = nil
            resources = []
            availability = .daemonUnavailable(message: error.localizedDescription)
        }
    }
}

