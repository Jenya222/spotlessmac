import Foundation
struct AppStorageSummary: Sendable {
    let appID: UUID
    let bundleBytes: Int64
    let cacheBytes: Int64
    let dataBytes: Int64
    let isComplete: Bool
    var confirmedTotalBytes: Int64 { bundleBytes + cacheBytes + dataBytes }
}
