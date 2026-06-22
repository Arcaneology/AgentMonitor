import Darwin
import Foundation

struct CommandResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

enum CommandExecutionError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

protocol CommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult
}

struct SystemCommandRunner: CommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let outputCollector = PipeDataCollector(pipe: standardOutput)
            let errorCollector = PipeDataCollector(pipe: standardError)

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.environment = ProcessInfo.processInfo.environment.merging([
                "LANG": "C",
                "LC_ALL": "C"
            ]) { _, fixedValue in fixedValue }

            do {
                try process.run()
            } catch {
                outputCollector.cancel()
                errorCollector.cancel()
                throw CommandExecutionError.launchFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    stop(process)
                    outputCollector.cancel()
                    errorCollector.cancel()
                    throw error
                }

                if Date() >= deadline {
                    stop(process)
                    outputCollector.cancel()
                    errorCollector.cancel()
                    throw CommandExecutionError.timedOut
                }

            }

            return CommandResult(
                terminationStatus: process.terminationStatus,
                standardOutput: outputCollector.finish(),
                standardError: errorCollector.finish()
            )
        }.value
    }
}

private func stop(_ process: Process) {
    process.terminate()

    let gracefulDeadline = Date().addingTimeInterval(0.1)
    while process.isRunning && Date() < gracefulDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    let forcedDeadline = Date().addingTimeInterval(0.1)
    while process.isRunning && Date() < forcedDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private final class PipeDataCollector: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func finish() -> Data {
        fileHandle.readabilityHandler = nil
        append(fileHandle.readDataToEndOfFile())

        return lock.withLock { data }
    }

    func cancel() {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            data.append(chunk)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
