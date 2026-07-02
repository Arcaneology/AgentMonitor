import XCTest
@testable import AgentMonitor

@MainActor
final class ServerModeControllerTests: XCTestCase {
    func testParsesSleepDisabledState() {
        XCTAssertEqual(
            ServerModeController.sleepDisabledState(from: #"    "SleepDisabled" = Yes"#),
            .enabled
        )
        XCTAssertEqual(
            ServerModeController.sleepDisabledState(from: #"    "SleepDisabled" = No"#),
            .disabled
        )
        XCTAssertEqual(ServerModeController.sleepDisabledState(from: ""), .unknown)
    }

    func testRefreshStartsCaffeinateWhenSleepDisabledIsEnabled() async {
        let runner = RecordingCommandRunner(responses: [
            .success(output: #"    "SleepDisabled" = Yes"#)
        ])
        let caffeinateManager = FakeCaffeinateManager()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            appPID: 123
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertTrue(snapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.startedPIDs, [123])
    }

    func testRefreshStopsCaffeinateWhenSleepDisabledIsDisabled() async {
        let runner = RecordingCommandRunner(responses: [
            .success(output: #"    "SleepDisabled" = No"#)
        ])
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertFalse(snapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.stopCount, 1)
    }

    func testSetEnabledUsesPasswordlessSudoWhenRuleExists() async {
        let runner = RecordingCommandRunner(responses: [
            .success(),
            .success(output: #"    "SleepDisabled" = Yes"#)
        ])
        let caffeinateManager = FakeCaffeinateManager()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager
        )

        let snapshot = await controller.setEnabled(true)
        let calls = await runner.calls

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(calls.map(\.executablePath), ["/usr/bin/sudo", "/usr/sbin/ioreg"])
        XCTAssertEqual(calls[0].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "1"])
    }

    func testSetEnabledInstallsLimitedSudoersRuleWhenSudoNeedsPassword() async {
        let runner = RecordingCommandRunner(responses: [
            .failure(error: "sudo: a password is required"),
            .success(),
            .success(),
            .success(output: #"    "SleepDisabled" = Yes"#)
        ])
        let caffeinateManager = FakeCaffeinateManager()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            currentUser: "agentuser"
        )

        let snapshot = await controller.setEnabled(true)
        let calls = await runner.calls

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(calls.map(\.executablePath), [
            "/usr/bin/sudo",
            "/usr/bin/osascript",
            "/usr/bin/sudo",
            "/usr/sbin/ioreg"
        ])
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("/private/etc/sudoers.d/agentmonitor-server-mode"))
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("agentuser ALL=(root) NOPASSWD"))
        XCTAssertEqual(calls[2].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "1"])
    }

    func testSudoersInstallerRejectsUnexpectedUsernames() {
        XCTAssertThrowsError(try ServerModeController.sudoersInstallShellCommand(for: "bad user"))
    }
}

private actor RecordingCommandRunner: CommandRunning {
    private var responses: [RecordedResponse]
    private(set) var calls: [RecordedCall] = []

    init(responses: [RecordedResponse]) {
        self.responses = responses
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        calls.append(RecordedCall(
            executablePath: executableURL.path,
            arguments: arguments
        ))
        guard !responses.isEmpty else {
            return RecordedResponse.success().result
        }
        return responses.removeFirst().result
    }
}

private struct RecordedCall: Equatable {
    let executablePath: String
    let arguments: [String]
}

private struct RecordedResponse {
    let result: CommandResult

    static func success(output: String = "") -> RecordedResponse {
        RecordedResponse(result: CommandResult(
            terminationStatus: 0,
            standardOutput: Data(output.utf8),
            standardError: Data()
        ))
    }

    static func failure(error: String) -> RecordedResponse {
        RecordedResponse(result: CommandResult(
            terminationStatus: 1,
            standardOutput: Data(),
            standardError: Data(error.utf8)
        ))
    }
}

@MainActor
private final class FakeCaffeinateManager: CaffeinateManaging {
    var isRunning: Bool
    private(set) var startedPIDs: [Int32] = []
    private(set) var stopCount = 0

    init(isRunning: Bool = false) {
        self.isRunning = isRunning
    }

    func start(appPID: Int32) throws {
        startedPIDs.append(appPID)
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}
