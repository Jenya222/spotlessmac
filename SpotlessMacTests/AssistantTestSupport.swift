import Foundation
@testable import SpotlessMac

final class FakeKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String
    init(_ key: String = "") { self.key = key }
    func readKey() -> String { lock.withLock { key } }
    func writeKey(_ newKey: String) {
        lock.withLock { key = newKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

func makeDefaults() -> UserDefaults {
    let name = "assistant.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
