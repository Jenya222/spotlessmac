import Foundation

enum VolumeSpaceReader {
    static func sample(at url: URL) async throws -> VolumeSample {
        try await Task.detached(priority: .utility) {
            let values = try url.resourceValues(forKeys: [.volumeIdentifierKey, .volumeAvailableCapacityKey])
            guard let id = values.volumeIdentifier, let available = values.volumeAvailableCapacity else {
                throw CocoaError(.fileReadUnknown)
            }
            return VolumeSample(volumeID: String(describing: id), availableBytes: Int64(available), sampledAt: Date())
        }.value
    }
}
