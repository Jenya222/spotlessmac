import Foundation

struct DockerCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum DockerCommandError: LocalizedError, Sendable {
    case executableNotFound
    case failed(arguments: [String], stderr: String, exitCode: Int32)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Docker CLI не найден. Установите Docker Desktop."
        case .failed(_, let stderr, _):
            stderr.isEmpty ? "Docker завершил команду с ошибкой." : stderr
        case .invalidOutput(let message):
            message
        }
    }
}

typealias RunDockerCommand = @Sendable ([String]) async throws -> DockerCommandResult

enum DockerCommandRunner {
    static func run(arguments: [String]) async throws -> DockerCommandResult {
        guard let executableURL = locateExecutable() else {
            throw DockerCommandError.executableNotFound
        }
        return try await run(executableURL: executableURL, arguments: arguments)
    }

    static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> DockerCommandResult {
        let runningProcess = RunningDockerProcess()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                try process.run()

                if runningProcess.attach(process) {
                    process.terminate()
                }

                async let outputData = output.fileHandleForReading.readToEnd()
                async let errorData = error.fileHandleForReading.readToEnd()

                try? output.fileHandleForWriting.close()
                try? error.fileHandleForWriting.close()
                process.waitUntilExit()
                let (capturedOutput, capturedError) = try await (outputData, errorData)
                return DockerCommandResult(
                    stdout: String(decoding: capturedOutput ?? Data(), as: UTF8.self),
                    stderr: String(decoding: capturedError ?? Data(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    exitCode: process.terminationStatus
                )
            }.value
        } onCancel: {
            runningProcess.cancel()
        }
        try Task.checkCancellation()
        return result
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

private final class RunningDockerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Returns true when cancellation won the race before the process attached.
    func attach(_ process: Process) -> Bool {
        lock.withLock {
            self.process = process
            return cancelled
        }
    }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return self.process
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}
