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
        XCTAssertEqual(IOKitSleepDisabledReader.state(from: kCFBooleanTrue), .enabled)
        XCTAssertEqual(IOKitSleepDisabledReader.state(from: kCFBooleanFalse), .disabled)
    }

    func testRefreshStartsCaffeinateWhenSleepDisabledIsEnabled() async {
        let runner = RecordingCommandRunner(responses: [])
        let caffeinateManager = FakeCaffeinateManager()
        let settingsStore = FakePowerModeSettingsStore()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled),
            appPID: 123
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(snapshot.requestedMode, .server)
        XCTAssertEqual(settingsStore.requestedMode, .server)
        XCTAssertTrue(snapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.startedPIDs, [123])
    }

    func testRefreshStopsCaffeinateWhenSleepDisabledIsDisabled() async {
        let runner = RecordingCommandRunner(responses: [])
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            settingsStore: FakePowerModeSettingsStore(),
            sleepDisabledReader: FakeSleepDisabledReader(state: .disabled)
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(snapshot.state, .disabled)
        XCTAssertFalse(snapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.stopCount, 1)
    }

    func testSetEnabledUsesPasswordlessSudoWhenRuleExists() async {
        let runner = RecordingCommandRunner(responses: [
            .success()
        ])
        let caffeinateManager = FakeCaffeinateManager()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            settingsStore: FakePowerModeSettingsStore(),
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled)
        )

        let snapshot = await controller.setEnabled(true)
        let calls = await runner.calls

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(calls.map(\.executablePath), ["/usr/bin/sudo"])
        XCTAssertEqual(calls[0].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "1"])
    }

    func testSetSleepModeDisablesSleepStopsCaffeinateAndRunsSleepNow() async {
        let runner = RecordingCommandRunner(responses: [
            .success(),
            .success()
        ])
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let settingsStore = FakePowerModeSettingsStore()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .disabled)
        )

        let snapshot = await controller.setMode(.sleep)
        let calls = await runner.calls

        XCTAssertEqual(settingsStore.requestedMode, .normal)
        XCTAssertEqual(snapshot.requestedMode, .normal)
        XCTAssertEqual(snapshot.effectiveMode, .normal)
        XCTAssertEqual(caffeinateManager.stopCount, 1)
        XCTAssertEqual(calls.map(\.executablePath), ["/usr/bin/sudo", "/usr/bin/sudo"])
        XCTAssertEqual(calls[0].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "0"])
        XCTAssertEqual(calls[1].arguments, ["-n", "/usr/bin/pmset", "sleepnow"])
    }

    func testRefreshMigratesStaleSleepRequestToNormalAfterWake() async {
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.requestedMode = .sleep
        let controller = ServerModeController(
            commandRunner: RecordingCommandRunner(responses: []),
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .disabled)
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(settingsStore.requestedMode, .normal)
        XCTAssertEqual(snapshot.requestedMode, .normal)
        XCTAssertEqual(snapshot.effectiveMode, .normal)
    }

    func testSetEnabledInstallsLimitedSudoersRuleWhenSudoNeedsPassword() async {
        let runner = RecordingCommandRunner(responses: [
            .failure(error: "sudo: a password is required"),
            .success(),
            .success()
        ])
        let caffeinateManager = FakeCaffeinateManager()
        let controller = ServerModeController(
            commandRunner: runner,
            caffeinateManager: caffeinateManager,
            settingsStore: FakePowerModeSettingsStore(),
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled),
            currentUser: "agentuser"
        )

        let snapshot = await controller.setEnabled(true)
        let calls = await runner.calls

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(calls.map(\.executablePath), [
            "/usr/bin/sudo",
            "/usr/bin/osascript",
            "/usr/bin/sudo"
        ])
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("/private/etc/sudoers.d/agentmonitor-server-mode"))
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("agentuser ALL=(root) NOPASSWD"))
        XCTAssertTrue(calls[1].arguments.joined(separator: " ").contains("/usr/bin/pmset sleepnow"))
        XCTAssertEqual(calls[2].arguments, ["-n", "/usr/bin/pmset", "disablesleep", "1"])
    }

    func testReconcileScheduleAppliesLatestEventOnce() async throws {
        let runner = RecordingCommandRunner(responses: [
            .success()
        ])
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.schedule = PowerModeSchedule(
            nightlySleep: PowerModeSchedule.default.nightlySleep,
            workdayServer: PowerModeScheduleRule(
                id: .workdayServer,
                mode: .server,
                hour: 8,
                minute: 0,
                weekdays: Set(2...6),
                isEnabled: true
            )
        )
        let controller = ServerModeController(
            commandRunner: runner,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled),
            calendar: makeCalendar()
        )

        let firstSnapshot = await controller.reconcileSchedule(now: try date("2026-06-22 08:01"))
        let secondSnapshot = await controller.reconcileSchedule(now: try date("2026-06-22 08:02"))
        let calls = await runner.calls

        XCTAssertEqual(firstSnapshot?.effectiveMode, .server)
        XCTAssertNil(secondSnapshot)
        XCTAssertEqual(calls.map(\.executablePath), ["/usr/bin/sudo"])
    }

    func testRefreshDoesNotOverrideExplicitNormalRequestWhenSleepDisabledStaysEnabled() async {
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.requestedMode = .normal
        let controller = ServerModeController(
            commandRunner: RecordingCommandRunner(responses: []),
            caffeinateManager: caffeinateManager,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled)
        )

        let snapshot = await controller.refresh()

        XCTAssertEqual(snapshot.requestedMode, .normal)
        XCTAssertEqual(snapshot.effectiveMode, .server)
        XCTAssertEqual(snapshot.displayedPowerMode, .server)
        XCTAssertFalse(snapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.stopCount, 1)
        XCTAssertNil(snapshot.message)
    }

    func testRefreshPreservesServerIntentAndProtectionAcrossTransientDisabledState() async {
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.requestedMode = .server
        let reader = FakeSleepDisabledReader(state: .disabled)
        let controller = ServerModeController(
            commandRunner: RecordingCommandRunner(responses: []),
            caffeinateManager: caffeinateManager,
            settingsStore: settingsStore,
            sleepDisabledReader: reader
        )

        let disabledSnapshot = await controller.refresh()
        reader.state = .enabled
        let recoveredSnapshot = await controller.refresh()

        XCTAssertEqual(settingsStore.requestedMode, .server)
        XCTAssertEqual(disabledSnapshot.requestedMode, .server)
        XCTAssertEqual(disabledSnapshot.effectiveMode, .normal)
        XCTAssertTrue(disabledSnapshot.isCaffeinateRunning)
        XCTAssertEqual(disabledSnapshot.message, "Server 请求仍在，但系统当前未启用 SleepDisabled。")
        XCTAssertEqual(recoveredSnapshot.effectiveMode, .server)
        XCTAssertTrue(recoveredSnapshot.isCaffeinateRunning)
        XCTAssertEqual(caffeinateManager.stopCount, 0)
    }

    func testSetModeNormalKeepsRequestedModeWhenSleepDisabledStaysEnabled() async {
        let caffeinateManager = FakeCaffeinateManager(isRunning: true)
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.requestedMode = .server
        let controller = ServerModeController(
            commandRunner: RecordingCommandRunner(responses: [.success()]),
            caffeinateManager: caffeinateManager,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .enabled),
            sleepDisabledPollAttempts: 1
        )

        let snapshot = await controller.setMode(.normal)

        XCTAssertEqual(settingsStore.requestedMode, .normal)
        XCTAssertEqual(snapshot.requestedMode, .normal)
        XCTAssertEqual(snapshot.effectiveMode, .server)
        XCTAssertEqual(snapshot.displayedPowerMode, .server)
        XCTAssertFalse(snapshot.isCaffeinateRunning)
        XCTAssertEqual(snapshot.message, "pmset 已执行，但系统仍处于 Server。")
    }

    func testSetModeServerKeepsIntentWhenSleepDisabledStaysDisabled() async {
        let settingsStore = FakePowerModeSettingsStore()
        let controller = ServerModeController(
            commandRunner: RecordingCommandRunner(responses: [.success()]),
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .disabled),
            sleepDisabledPollAttempts: 1
        )

        let snapshot = await controller.setMode(.server)

        XCTAssertEqual(settingsStore.requestedMode, .server)
        XCTAssertEqual(snapshot.requestedMode, .server)
        XCTAssertEqual(snapshot.effectiveMode, .normal)
        XCTAssertEqual(snapshot.displayedPowerMode, .normal)
        XCTAssertTrue(snapshot.isCaffeinateRunning)
        XCTAssertEqual(snapshot.message, "pmset 已执行，但系统未进入 Server；已保留你的 Server 请求。")
    }

    func testScheduleFailureKeepsErrorAndRemainsRetryable() async throws {
        let runner = RecordingCommandRunner(responses: [
            .failure(error: "sudo failed"),
            .failure(error: "authorization cancelled"),
            .failure(error: "sudo failed"),
            .failure(error: "authorization cancelled")
        ])
        let settingsStore = FakePowerModeSettingsStore()
        settingsStore.schedule = PowerModeSchedule(
            nightlySleep: PowerModeSchedule.default.nightlySleep,
            workdayServer: PowerModeScheduleRule(
                id: .workdayServer,
                mode: .server,
                hour: 8,
                minute: 0,
                weekdays: Set(2...6),
                isEnabled: true
            )
        )
        let controller = ServerModeController(
            commandRunner: runner,
            settingsStore: settingsStore,
            sleepDisabledReader: FakeSleepDisabledReader(state: .disabled),
            calendar: makeCalendar()
        )

        let first = await controller.reconcileSchedule(now: try date("2026-06-22 08:01"))
        let second = await controller.reconcileSchedule(now: try date("2026-06-22 08:02"))

        XCTAssertNil(settingsStore.lastAppliedScheduleEventID)
        XCTAssertTrue(first?.message?.contains("切换 Server 失败") == true)
        XCTAssertNotNil(second)
    }

    func testCaffeinateArgumentsProtectDisplayAndRemainBoundToApp() {
        XCTAssertEqual(
            SystemCaffeinateManager.arguments(appPID: 321),
            ["-d", "-i", "-m", "-s", "-w", "321"]
        )
    }

    func testLegacyDefaultsMigrationCopiesKnownSettingsWithoutOverwritingCurrentValues() {
        let suiteName = "AgentMonitorTests.LegacyDefaults.\(UUID().uuidString)"
        guard let destination = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { destination.removePersistentDomain(forName: suiteName) }
        destination.set(PowerMode.normal.rawValue, forKey: "powerMode.requestedMode")

        LegacyUserDefaultsMigrator.migrateIfNeeded(
            bundleID: LegacyUserDefaultsMigrator.currentBundleID,
            destination: destination,
            legacyDomain: [
                "powerMode.requestedMode": PowerMode.server.rawValue,
                "powerMode.lastAppliedScheduleEventID": "workdayServer-1",
                "temperature.highTemperatureAlertEnabled": false,
                "unrelated.setting": "do-not-copy"
            ]
        )

        XCTAssertEqual(destination.string(forKey: "powerMode.requestedMode"), PowerMode.normal.rawValue)
        XCTAssertEqual(
            destination.string(forKey: "powerMode.lastAppliedScheduleEventID"),
            "workdayServer-1"
        )
        XCTAssertEqual(destination.object(forKey: "temperature.highTemperatureAlertEnabled") as? Bool, false)
        XCTAssertNil(destination.object(forKey: "unrelated.setting"))
    }

    func testLegacyDefaultsMigrationDoesNotRunForDebugIdentity() {
        let suiteName = "AgentMonitorTests.LegacyDefaults.Debug.\(UUID().uuidString)"
        guard let destination = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated UserDefaults suite")
        }
        defer { destination.removePersistentDomain(forName: suiteName) }

        LegacyUserDefaultsMigrator.migrateIfNeeded(
            bundleID: "com.lumos.AgentMonitor.Debug",
            destination: destination,
            legacyDomain: ["powerMode.requestedMode": PowerMode.server.rawValue]
        )

        XCTAssertNil(destination.object(forKey: "powerMode.requestedMode"))
    }

    func testSudoersInstallerRejectsUnexpectedUsernames() {
        XCTAssertThrowsError(try ServerModeController.sudoersInstallShellCommand(for: "bad user"))
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = makeCalendar()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: value))
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

@MainActor
private final class FakePowerModeSettingsStore: PowerModeSettingsStoring {
    private var requestedModeStorage: PowerMode?
    var schedule: PowerModeSchedule = .default
    var lastAppliedScheduleEventID: String?

    var requestedMode: PowerMode {
        get { requestedModeStorage ?? .normal }
        set { requestedModeStorage = newValue }
    }

    var hasRequestedMode: Bool {
        requestedModeStorage != nil
    }
}

private final class FakeSleepDisabledReader: SleepDisabledReading, @unchecked Sendable {
    var state: ServerModeState

    init(state: ServerModeState) {
        self.state = state
    }

    func read() -> ServerModeState {
        state
    }
}
