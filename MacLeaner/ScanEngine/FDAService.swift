import Darwin

enum FDAStatus: Sendable {
    case unknown, granted, denied
}

enum FDAService {
    // Probes a TCC-protected path. Returns .granted if readable, .denied otherwise.
    static func detect() -> FDAStatus {
        let path = "/Library/Application Support/com.apple.TCC/TCC.db"
        return access(path, R_OK) == 0 ? .granted : .denied
    }
}
