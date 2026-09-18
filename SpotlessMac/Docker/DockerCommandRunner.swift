import Foundation

struct DockerCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum DockerCommandError: LocalizedError, Sendable {
    case executableNotFound
    case failed(arguments: [String], stderr: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Docker CLI не найден. Установите Docker Desktop."
        case .failed(_, let stderr, _):
            stderr.isEmpty ? "Docker завершил команду с ошибкой." : stderr
        }
    }
}

typealias RunDockerCommand = @Sendable ([String]) async throws -> DockerCommandResult

enum DockerCommandRunner {
    static func run(arguments: [String]) async throws -> DockerCommandResult {
        guard let executableURL = locateExecutable() else {
            throw DockerCommandError.executableNotFound
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            return DockerCommandResult(
                stdout: String(decoding: outputData, as: UTF8.self),
                stderr: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )
        }.value
    }

    static func locateExecutable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            URL(filePath: "/usr/local/bin/docker"),
            URL(filePath: "/opt/homebrew/bin/docker"),
            URL(filePath: "/Applications/Docker.app/Contents/Resources/bin/docker"),
            homeDirectory.appending(path: ".docker/bin/docker"),
        ]
        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false))
        }
    }
}

