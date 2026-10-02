import Foundation
import AppKit

enum OwnerActivityChecker {
    static func check(_ item: ScanItem) async -> OwnerActivity {
        guard item.cleanupPolicy.requiresClosedOwner else { return .closed }
        let owner = item.owner ?? ""
        let apps = await MainActor.run { NSWorkspace.shared.runningApplications.compactMap(\.localizedName) }
        if apps.contains(where: { $0.localizedCaseInsensitiveContains(owner) || owner.localizedCaseInsensitiveContains($0) }) { return .running }
        return await Task.detached(priority: .utility) {
            let process = Process(); let output = Pipe()
            process.executableURL = URL(filePath: "/bin/ps"); process.arguments = ["-axo", "comm="]
            process.standardOutput = output; process.standardError = Pipe()
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return .unknown }
                let commands = String(decoding: data, as: UTF8.self).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                let terms: [String]
                switch item.category {
                case .projectArtifacts: terms = ["node", "npm", "pnpm", "yarn", "bun", "swift", "xcodebuild", "cmake", "ninja", "make", "python", "uv"]
                case .modelCaches: terms = ["python", "huggingface", "hf", "uv", "anythingllm", "comfy"]
                case .recordings: terms = ["wooffoow"]
                default: terms = owner.contains("Python") ? ["uv", "python"] : owner.contains("npm") ? ["node", "npm", "pnpm", "yarn", "bun"] : [owner.lowercased()]
                }
                for command in commands {
                    let name = URL(filePath: command).lastPathComponent
                    if terms.contains(where: { name == $0 || name.hasPrefix($0 + " ") || name.hasPrefix($0 + "3") || command.contains("/" + $0 + ".app/") }) { return .running }
                }
                return .closed
            } catch { return .unknown }
        }.value
    }
}
