import Foundation

enum StorageRootKind: String { case projects, huggingFace }
enum StorageRootRegistry {
    static func isAdmissible(_ url: URL) -> Bool {
        let path = PathPolicy.canonical(url)
        let reserved = ["/", "/Users", "/Volumes", "/Applications", "/Library", "/private", "/private/var", "/usr", "/opt", PathPolicy.canonical(FileManager.default.homeDirectoryForCurrentUser)]
        return !reserved.contains(path) && !PathPolicy.isForbidden(path) && StorageFileIdentity.read(url)?.isDirectory == true
    }
    static func register(_ url: URL, kind: StorageRootKind, store: UserDefaults = .standard) throws {
        guard isAdmissible(url) else { throw CocoaError(.fileReadNoPermission) }
        let path = PathPolicy.canonical(url)
        let key = "storageRoots." + kind.rawValue
        var values = store.stringArray(forKey: key) ?? []
        if !values.contains(path) { values.append(path); store.set(values, forKey: key) }
    }
    static func roots(kind: StorageRootKind, store: UserDefaults = .standard) -> [URL] {
        (store.stringArray(forKey: "storageRoots." + kind.rawValue) ?? []).map { URL(filePath: $0) }.filter(isAdmissible)
    }
}
