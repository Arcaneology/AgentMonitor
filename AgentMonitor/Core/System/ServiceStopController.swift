import Darwin
import Foundation

enum StopOutcome: Equatable, Sendable {
    case stopped
    case requiresForce([Int32])
    case failed(String)
}

protocol ServiceStopping: Sendable {
    func stop(_ service: MonitoredService) async -> StopOutcome
    func forceStop(_ service: MonitoredService) async -> StopOutcome
}

protocol ProcessSignaling: Sendable {
    func send(signal: Int32, to pid: Int32) throws
}

struct ProcessSignalError: Error, Equatable, Sendable {
    let code: Int32
}

struct SystemProcessSignaler: ProcessSignaling {
    func send(signal: Int32, to pid: Int32) throws {
        guard Darwin.kill(pid, signal) == 0 else {
            throw ProcessSignalError(code: errno)
        }
    }
}

struct ServiceStopController: ServiceStopping {
    private let ownerUID: UInt32
    private let processCollector: any ProcessCollecting
    private let processSignaler: any ProcessSignaling
    private let commandRunner: any CommandRunning
    private let waitTimeout: TimeInterval

    init(
        ownerUID: UInt32,
        processCollector: any ProcessCollecting,
        processSignaler: any ProcessSignaling,
        commandRunner: any CommandRunning,
        waitTimeout: TimeInterval = 3
    ) {
        self.ownerUID = ownerUID
        self.processCollector = processCollector
        self.processSignaler = processSignaler
        self.commandRunner = commandRunner
        self.waitTimeout = waitTimeout
    }

    func stop(_ service: MonitoredService) async -> StopOutcome {
        switch validate(service.processes) {
        case .failure(let error):
            return .failed(error.message)
        case .success(let processes):
            if service.kind == .launchAgent {
                guard let label = service.launchAgentLabel else {
                    return .failed("缺少 LaunchAgent 标识，已取消停止。")
                }

                do {
                    let result = try await commandRunner.run(
                        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                        arguments: ["bootout", "gui/\(ownerUID)/\(label)"],
                        timeout: 3
                    )
                    guard result.terminationStatus == 0 else {
                        let message = String(decoding: result.standardError, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return .failed(message.isEmpty ? "launchctl 停止失败。" : message)
                    }
                } catch {
                    return .failed("launchctl 停止失败：\(error)")
                }
            } else {
                do {
                    for process in processes {
                        try processSignaler.send(signal: SIGTERM, to: process.id.pid)
                    }
                } catch {
                    return .failed("发送 SIGTERM 失败：\(error)")
                }
            }

            let alivePIDs = await waitForExit(processes)
            return alivePIDs.isEmpty ? .stopped : .requiresForce(alivePIDs)
        }
    }

    func forceStop(_ service: MonitoredService) async -> StopOutcome {
        let matchingProcesses = service.processes.filter { expected in
            guard
                expected.ownerUID == ownerUID,
                expected.id.pid != getpid(),
                let current = processCollector.collect(pid: expected.id.pid)
            else {
                return false
            }
            return current.ownerUID == ownerUID && current.id == expected.id
        }

        guard !matchingProcesses.isEmpty else { return .stopped }

        do {
            for process in matchingProcesses {
                try processSignaler.send(signal: SIGKILL, to: process.id.pid)
            }
        } catch {
            return .failed("发送 SIGKILL 失败：\(error)")
        }

        let alivePIDs = await waitForExit(matchingProcesses)
        return alivePIDs.isEmpty
            ? .stopped
            : .failed("进程仍在运行：\(alivePIDs.map(String.init).joined(separator: ", "))")
    }

    private func validate(
        _ processes: [MonitoredProcess]
    ) -> Result<[MonitoredProcess], ValidationError> {
        guard !processes.isEmpty else {
            return .failure(ValidationError(message: "没有可停止的进程。"))
        }

        for expected in processes {
            guard expected.ownerUID == ownerUID else {
                return .failure(ValidationError(message: "进程不属于当前用户，已取消停止。"))
            }
            guard expected.id.pid != getpid() else {
                return .failure(ValidationError(message: "不能从 Agent Monitor 中停止自身进程。"))
            }
            guard let current = processCollector.collect(pid: expected.id.pid) else {
                return .failure(ValidationError(message: "进程已经退出，列表即将刷新。"))
            }
            guard current.ownerUID == ownerUID, current.id == expected.id else {
                return .failure(ValidationError(message: "进程状态已变化，已取消停止以避免误操作。"))
            }
        }
        return .success(processes)
    }

    private func waitForExit(_ processes: [MonitoredProcess]) async -> [Int32] {
        let deadline = Date().addingTimeInterval(waitTimeout)

        while true {
            let alivePIDs = processes.compactMap { expected -> Int32? in
                guard let current = processCollector.collect(pid: expected.id.pid) else { return nil }
                return current.id == expected.id ? expected.id.pid : nil
            }

            if alivePIDs.isEmpty || Date() >= deadline {
                return alivePIDs
            }

            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return alivePIDs
            }
        }
    }
}

private struct ValidationError: Error {
    let message: String
}
