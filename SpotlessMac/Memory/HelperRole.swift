import Foundation

/// What a Chromium/Electron helper process does, read from its command line.
/// Chrome does not expose which tab or extension lives in which process, so
/// this is the most precise label available from outside the browser.
enum HelperRole: String, Sendable, Equatable, CaseIterable {
    case page, browserExtension, gpu, network, storage, audio, video, utility

    var label: String {
        switch self {
        case .page: "Вкладка / страница"
        case .browserExtension: "Расширение"
        case .gpu: "Графика (GPU)"
        case .network: "Сеть"
        case .storage: "Хранилище"
        case .audio: "Звук"
        case .video: "Видео"
        case .utility: "Служебный процесс"
        }
    }

    /// Plural label for the per-group summary line.
    var summaryLabel: String {
        switch self {
        case .page: "Вкладки"
        case .browserExtension: "Расширения"
        default: label
        }
    }

    static func classify(_ arguments: [String]) -> HelperRole? {
        guard let type = value(of: "--type=", in: arguments) else { return nil }
        switch type {
        case "renderer":
            return arguments.contains("--extension-process") ? .browserExtension : .page
        case "gpu-process":
            return .gpu
        case "utility":
            let subType = (value(of: "--utility-sub-type=", in: arguments) ?? "").lowercased()
            if subType.contains("network") { return .network }
            if subType.contains("storage") { return .storage }
            if subType.contains("audio") { return .audio }
            if subType.contains("video") { return .video }
            return .utility
        default:
            return nil
        }
    }

    private static func value(of prefix: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

/// Parses the `KERN_PROCARGS2` buffer: argc (Int32), exec path, NUL padding,
/// then argc NUL-terminated arguments followed by the environment.
enum ProcessArguments {
    static func parse(_ buffer: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count > headerSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = headerSize
        while index < buffer.count, buffer[index] != 0 { index += 1 } // exec path
        while index < buffer.count, buffer[index] == 0 { index += 1 } // padding
        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.isEmpty ? nil : arguments
    }
}

struct HelperRoleTotal: Equatable, Sendable {
    let role: HelperRole
    let bytes: UInt64
    let count: Int
}

extension AppMemoryGroup {
    /// Footprint per helper role, largest first. Processes without a role
    /// (the app's own main process, crash reporter…) are not included.
    var roleTotals: [HelperRoleTotal] {
        var totals: [HelperRole: (bytes: UInt64, count: Int)] = [:]
        for process in processes {
            guard let role = process.role else { continue }
            let current = totals[role] ?? (0, 0)
            totals[role] = (current.bytes + process.footprint, current.count + 1)
        }
        return totals
            .map { HelperRoleTotal(role: $0.key, bytes: $0.value.bytes, count: $0.value.count) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.role.rawValue < $1.role.rawValue }
    }

    /// Browsers run extensions; Electron apps (Slack, VS Code…) do not.
    var looksLikeBrowser: Bool {
        processes.contains { $0.role == .browserExtension }
    }
}
