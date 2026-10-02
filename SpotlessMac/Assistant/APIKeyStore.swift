import Foundation

protocol APIKeyStoring: Sendable {
    func readKey() -> String
    func writeKey(_ key: String)
}

struct KeychainAPIKeyStore: APIKeyStoring {
    private let account = "assistantAPIKey"

    func readKey() -> String {
        KeychainStore.read(account: account).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // An empty key removes the Keychain item.
    func writeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(account: account)
        } else {
            KeychainStore.write(Data(trimmed.utf8), account: account)
        }
    }
}
