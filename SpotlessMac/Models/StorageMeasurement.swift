import Foundation
import Darwin

struct StorageMeasurement: Sendable, Equatable {
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var unreadableEntries: Int = 0
    var isComplete: Bool = true
}

struct StorageNode: Identifiable, Sendable {
    let url: URL
    let measurement: StorageMeasurement
    let isDirectory: Bool
    let isPackage: Bool
    var id: String { url.standardizedFileURL.path(percentEncoded: false) }
}

struct StorageFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    static func read(_ url: URL) -> Self? {
        var info = stat()
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard lstat(path, &info) == 0 else { return nil }
        return Self(device: UInt64(info.st_dev), inode: info.st_ino, mode: info.st_mode)
    }
    var isSymbolicLink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isRegularFile: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
}
