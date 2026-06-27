import Foundation
import Observation

@Observable
@MainActor
final class LicenseManager {
    private static let trialCleansAllowed = 1

    enum LicenseState: Equatable {
        case trial(usedCleans: Int, allowed: Int)
        case activated(email: String)
    }

    private(set) var state: LicenseState = .trial(usedCleans: 0, allowed: trialCleansAllowed)
    private(set) var activationError: String?

    var canClean: Bool {
        switch state {
        case .activated: return true
        case .trial(let used, let allowed): return used < allowed
        }
    }

    var isActivated: Bool {
        if case .activated = state { return true }
        return false
    }

    init() { load() }

    func activate(key: String) {
        activationError = nil
        do {
            let payload = try LicenseValidator.validate(key)
            guard payload.productID == "spotlessmac-v1" else {
                activationError = "Лицензия не предназначена для этого приложения."
                return
            }
            KeychainStore.write(Data(key.utf8), account: "licenseKey")
            state = .activated(email: payload.email)
        } catch LicenseError.invalidSignature {
            activationError = "Недействительный ключ лицензии."
        } catch {
            activationError = "Неверный формат ключа лицензии."
        }
    }

    // Call after each successful clean cycle to consume one trial use.
    // No-op when already activated.
    func recordClean() {
        guard case .trial(let used, let allowed) = state else { return }
        let newCount = min(used + 1, 255)
        KeychainStore.write(Data([UInt8(newCount)]), account: "trialCleans")
        state = .trial(usedCleans: newCount, allowed: allowed)
    }

    private func load() {
        if let keyData = KeychainStore.read(account: "licenseKey"),
           let key = String(data: keyData, encoding: .utf8),
           let payload = try? LicenseValidator.validate(key),
           payload.productID == "spotlessmac-v1" {
            state = .activated(email: payload.email)
            return
        }
        let used: Int
        if let data = KeychainStore.read(account: "trialCleans"), let byte = data.first {
            used = Int(byte)
        } else {
            used = 0
        }
        state = .trial(usedCleans: used, allowed: Self.trialCleansAllowed)
    }
}
