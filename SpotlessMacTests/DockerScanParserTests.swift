import XCTest
@testable import SpotlessMac

final class DockerScanParserTests: XCTestCase {
    func testSnapshotIncludesOnlyInactiveUnreferencedAndReclaimableResources() throws {
        let containers = Data(#"""
        [
          {
            "Id": "container-stopped",
            "Name": "/old-api",
            "Image": "sha256:image-used",
            "Created": "2026-08-01T10:00:00Z",
            "State": {"Running": false, "Status": "exited", "FinishedAt": "2026-08-02T10:00:00Z"},
            "SizeRw": 4096
          },
          {
            "Id": "container-running",
            "Name": "/database",
            "Image": "sha256:image-running",
            "Created": "2026-08-01T10:00:00Z",
            "State": {"Running": true, "Status": "running", "FinishedAt": "0001-01-01T00:00:00Z"},
            "SizeRw": 8192
          }
        ]
        """#.utf8)
        let images = Data(#"""
        [
          {"Id": "sha256:image-used", "RepoTags": ["api:latest"], "Created": "2026-07-01T10:00:00Z", "Size": 1000},
          {"Id": "sha256:image-running", "RepoTags": ["postgres:latest"], "Created": "2026-07-01T10:00:00Z", "Size": 2000},
          {"Id": "sha256:image-dangling", "RepoTags": ["<none>:<none>"], "Created": "2026-07-01T10:00:00Z", "Size": 3000},
          {"Id": "sha256:image-tagged", "RepoTags": ["web:old"], "Created": "2026-06-01T10:00:00Z", "Size": 4000}
        ]
        """#.utf8)
        let volumes = Data(#"""
        [{"Name": "database-backup", "CreatedAt": "2026-05-01T10:00:00Z", "Labels": {"project": "demo"}}]
        """#.utf8)
        let buildCache = """
        {"ID":"cache-old","Reclaimable":true,"Size":"2.5MB","LastAccessedAt":"2026-09-01T10:00:00Z","Description":"build stage"}
        {"ID":"cache-recent","Reclaimable":true,"Size":"1MB","LastAccessedAt":"2026-09-17T10:00:00Z","Description":"recent stage"}
        {"ID":"cache-active","Reclaimable":false,"Size":"5MB","LastAccessedAt":"2026-08-01T10:00:00Z","Description":"active stage"}
        """

        let snapshot = try DockerScanParser.makeSnapshot(
            containerJSON: containers,
            imageJSON: images,
            volumeJSON: volumes,
            buildCacheJSON: buildCache,
            now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-18T10:00:00Z"))
        )

        XCTAssertEqual(snapshot.resources.map(\.id), [
            "cache-old",
            "sha256:image-dangling",
            "sha256:image-tagged",
            "container-stopped",
            "database-backup",
        ])
        XCTAssertEqual(snapshot.resources.map(\.kind), [
            .buildCache, .image, .image, .container, .volume,
        ])
        XCTAssertEqual(snapshot.resources.map(\.isSelected), [true, true, false, false, false])
        XCTAssertEqual(snapshot.resources.map(\.risk), [
            .rebuildable, .rebuildable, .review, .review, .dataLoss,
        ])
        XCTAssertEqual(snapshot.resources.first?.size, 2_500_000)
        XCTAssertEqual(snapshot.referencedImageIDs, ["sha256:image-used", "sha256:image-running"])
        XCTAssertEqual(snapshot.danglingVolumeNames, ["database-backup"])
        XCTAssertEqual(snapshot.reclaimableBuildCacheIDs, ["cache-old"])
    }

    func testImageIDsAreNormalizedBeforeReferenceComparison() throws {
        let containers = Data(#"""
        [{"Id":"container","Name":"/api","Image":"ABC123","Created":"2026-01-01T00:00:00Z","State":{"Running":false,"Status":"exited","FinishedAt":"2026-01-02T00:00:00Z"},"SizeRw":1}]
        """#.utf8)
        let images = Data(#"""
        [{"Id":"sha256:abc123","RepoTags":["api:latest"],"Created":"2026-01-01T00:00:00Z","Size":1}]
        """#.utf8)

        let snapshot = try DockerScanParser.makeSnapshot(
            containerJSON: containers,
            imageJSON: images,
            volumeJSON: Data("[]".utf8),
            buildCacheJSON: "",
            now: Date()
        )

        XCTAssertFalse(snapshot.resources.contains { $0.kind == .image })
    }
}
