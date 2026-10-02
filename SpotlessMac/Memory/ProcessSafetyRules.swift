import Darwin
import Foundation

enum QuitDecision: Sendable, Equatable {
    case allowed
    case denied(String)
}

/// Gate for quitting applications — the memory counterpart of `SafetyRules`.
enum ProcessSafetyRules {
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "Finder", "Dock", "SystemUIServer", "ControlCenter",
    ]
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.loginwindow",
    ]

    static func canQuit(
        _ group: AppMemoryGroup,
        runningApps: [RunningAppInfo],
        currentUID: uid_t,
        ownBundlePath: String,
        ownPID: pid_t
    ) -> QuitDecision {
        switch group.kind {
        case .system: return .denied("Системные процессы нельзя завершать из SpotlessMac.")
        case .other: return .denied("Это процессы командной строки — завершите их там, где запускали.")
        case .userApp: break
        }
        guard let bundlePath = group.bundlePath else { return .denied("Не найдено приложение.") }
        if bundlePath == ownBundlePath || group.processes.contains(where: { $0.pid == ownPID }) {
            return .denied("Это сам SpotlessMac.")
        }
        if group.processes.contains(where: { $0.uid != currentUID }) {
            return .denied("Часть процессов запущена другим пользователем или системой.")
        }
        if group.processes.contains(where: { protectedNames.contains($0.name) })
            || runningApps.contains(where: { $0.bundleIdentifier.map(protectedBundleIDs.contains) == true }) {
            return .denied("Это системный компонент macOS.")
        }
        if runningApps.isEmpty {
            return .denied("Приложение не открыто — работают только его фоновые службы.")
        }
        let quittable = runningApps.contains {
            $0.policy == .regular || ($0.policy == .accessory && !BundlePath.isSystem(bundlePath))
        }
        if !quittable {
            return .denied("Это фоновая служба, а не обычное приложение.")
        }
        return .allowed
    }
}
