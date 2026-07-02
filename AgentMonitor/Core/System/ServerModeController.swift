import Darwin
import Foundation

enum ServerModeState: Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

struct ServerModeSnapshot: Equatable, Sendable {
    var state: ServerModeState
    var isCaffeinateRunning: Bool
    var message: String?

    static let unknown = ServerModeSnapshot(
        state: .unknown,
        isCaffeinateRunning: false,
        message: nil
    )

    var isEnabled: Bool { state == .enabled }

    func withMessage(_ message: String?) -> ServerModeSnapshot {
        ServerModeSnapshot(
            state: state,
            isCaffeinateRunning: isCaffeinateRunning,
            message: message
        )
    }
}

@MainActor
protocol ServerModeControlling: AnyObject {
    func refresh() async -> ServerModeSnapshot
    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot
}

@MainActor
protocol CaffeinateManaging: AnyObject {
    var isRunning: Bool { get }

    func start(appPID: Int32) throws
    func stop()
}

@MainActor
final class ServerModeController: ServerModeControlling {
    private let commandRunner: any CommandRunning
    private let caffeinateManager: any CaffeinateManaging
    private let appPID: Int32
    private let currentUser: String

    init(
        commandRunner: any CommandRunning,
        caffeinateManager: any CaffeinateManaging = SystemCaffeinateManager(),
        appPID: Int32 = getpid(),
        currentUser: String = NSUserName()
    ) {
        self.commandRunner = commandRunner
        self.caffeinateManager = caffeinateManager
        self.appPID = appPID
        self.currentUser = currentUser
    }

    func refresh() async -> ServerModeSnapshot {
        do {
            let state = try await readSleepDisabledState()
            switch state {
            case .enabled:
                do {
                    try ensureCaffeinateRunning()
                    return ServerModeSnapshot(
                        state: .enabled,
                        isCaffeinateRunning: caffeinateManager.isRunning,
                        message: nil
                    )
                } catch {
                    return ServerModeSnapshot(
                        state: .enabled,
                        isCaffeinateRunning: false,
                        message: "caffeinate 启动失败：\(error.localizedDescription)"
                    )
                }

            case .disabled:
                caffeinateManager.stop()
                return ServerModeSnapshot(
                    state: .disabled,
                    isCaffeinateRunning: false,
                    message: nil
                )

            case .unknown:
                return ServerModeSnapshot(
                    state: .unknown,
                    isCaffeinateRunning: caffeinateManager.isRunning,
                    message: "无法确认 SleepDisabled 状态。"
                )
            }
        } catch {
            return ServerModeSnapshot(
                state: .unknown,
                isCaffeinateRunning: caffeinateManager.isRunning,
                message: "读取 Server 状态失败：\(error.localizedDescription)"
            )
        }
    }

    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot {
        do {
            try await setSleepDisabled(enabled)
        } catch {
            return (await refresh()).withMessage("切换 Server 失败：\(errorMessage(from: error))")
        }

        let snapshot = await refresh()
        guard snapshot.state != .unknown else { return snapshot }

        if snapshot.isEnabled != enabled {
            return snapshot.withMessage("pmset 已执行，但系统状态未变更。")
        }
        return snapshot
    }

    private func ensureCaffeinateRunning() throws {
        guard !caffeinateManager.isRunning else { return }
        try caffeinateManager.start(appPID: appPID)
    }

    private func readSleepDisabledState() async throws -> ServerModeState {
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/ioreg"),
            arguments: ["-r", "-k", "SleepDisabled"],
            timeout: 2
        )
        guard result.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(result.errorText)
        }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        return Self.sleepDisabledState(from: output)
    }

    private func setSleepDisabled(_ enabled: Bool) async throws {
        let value = enabled ? "1" : "0"
        let firstAttempt = try await runSudoPMSet(value)
        if firstAttempt.terminationStatus == 0 {
            return
        }

        try await installSudoersRule()

        let retry = try await runSudoPMSet(value)
        guard retry.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(retry.errorText)
        }
    }

    private func runSudoPMSet(_ value: String) async throws -> CommandResult {
        try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-n", "/usr/bin/pmset", "disablesleep", value],
            timeout: 5
        )
    }

    private func installSudoersRule() async throws {
        let shellCommand = try Self.sudoersInstallShellCommand(for: currentUser)
        let script = "do shell script \(Self.appleScriptLiteral(shellCommand)) with administrator privileges"
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeout: 60
        )
        guard result.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(result.errorText)
        }
    }

    static func sleepDisabledState(from output: String) -> ServerModeState {
        for line in output.split(separator: "\n") where line.contains("\"SleepDisabled\"") {
            if line.contains("Yes") { return .enabled }
            if line.contains("No") { return .disabled }
        }
        return .unknown
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func sudoersInstallShellCommand(for user: String) throws -> String {
        guard isSupportedSudoersUser(user) else {
            throw ServerModeError.unsupportedUser(user)
        }

        let rule = """
        # Installed by Agent Monitor. Allows only Server mode sleep toggles.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1
        """
        let sudoersPath = "/private/etc/sudoers.d/agentmonitor-server-mode"
        return """
        umask 022
        tmp=$(/usr/bin/mktemp /private/tmp/agentmonitor-sudoers.XXXXXX) || exit 1
        /bin/cat > "$tmp" <<'AGENT_MONITOR_SUDOERS'
        \(rule)
        AGENT_MONITOR_SUDOERS
        /bin/chmod 0440 "$tmp"
        /usr/sbin/chown root:wheel "$tmp"
        /usr/sbin/visudo -cf "$tmp" || { /bin/rm -f "$tmp"; exit 1; }
        /bin/mv "$tmp" \(shellLiteral(sudoersPath))
        """
    }

    private static func isSupportedSudoersUser(_ user: String) -> Bool {
        guard !user.isEmpty else { return false }
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return user.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func shellLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func errorMessage(from error: Error) -> String {
        if let error = error as? ServerModeError {
            return error.message
        }
        return error.localizedDescription
    }
}

@MainActor
final class SystemCaffeinateManager: CaffeinateManaging {
    private var process: Process?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func start(appPID: Int32) throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-m", "-s", "-w", String(appPID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }
}

private enum ServerModeError: Error {
    case commandFailed(String)
    case unsupportedUser(String)

    var message: String {
        switch self {
        case .commandFailed(let text):
            return text.isEmpty ? "命令执行失败。" : text
        case .unsupportedUser(let user):
            return "当前用户名不适合写入 sudoers：\(user)"
        }
    }
}

private extension CommandResult {
    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
