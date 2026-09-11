import XCTest
@testable import AgentMonitor

@MainActor
final class TemperatureReaderTests: XCTestCase {
    func testComputerTemperaturePrefersDieSensorsAndIgnoresInvalidValues() {
        let celsius = TemperatureAggregator.computerTemperature(from: [
            TemperatureSensorReading(name: "gas gauge battery", celsius: 32),
            TemperatureSensorReading(name: "PMU tdev1", celsius: -21.8),
            TemperatureSensorReading(name: "PMU tcal", celsius: 51.8),
            TemperatureSensorReading(name: "NAND CH0 temp", celsius: 39),
            TemperatureSensorReading(name: "PMU tdie8", celsius: 49),
            TemperatureSensorReading(name: "PMU tdie1", celsius: 48.8)
        ])

        XCTAssertEqual(celsius, 49)
    }

    func testComputerTemperatureFallsBackToValidSensorsWhenDieSensorsAreMissing() {
        let celsius = TemperatureAggregator.computerTemperature(from: [
            TemperatureSensorReading(name: "PMU tdev4", celsius: 38.4),
            TemperatureSensorReading(name: "PMU tdev8", celsius: 37.6)
        ])

        XCTAssertEqual(celsius, 38.4)
    }

    func testPruningKeepsOnlyTheLastHour() {
        let now = Date(timeIntervalSince1970: 7_200)
        let samples = TemperatureAggregator.pruningSamples(
            [
                TemperatureSample(date: Date(timeIntervalSince1970: 0), celsius: 40),
                TemperatureSample(date: Date(timeIntervalSince1970: 3_600), celsius: 41),
                TemperatureSample(date: now, celsius: 48)
            ],
            now: now
        )

        XCTAssertEqual(samples.map(\.celsius), [41, 48])
    }

    func testStoreRecordsCurrentTemperatureAndDropsSamplesOlderThanOneHour() {
        let reader = FakeTemperatureReader(celsius: 47)
        let store = TemperatureStore(reader: reader)
        let now = Date(timeIntervalSince1970: 10_000)

        store.record(40, at: now.addingTimeInterval(-3_601))
        store.refresh(now: now)

        XCTAssertEqual(store.currentCelsius, 47)
        XCTAssertEqual(store.menuBarText, "47°C")
        XCTAssertEqual(store.samples.map(\.celsius), [47])
    }

    func testAlertLevelStaysNoneWhenDisabledOrBelowThreshold() {
        XCTAssertEqual(TemperatureAlertLevel.level(for: 79, isEnabled: true), .none)
        XCTAssertEqual(TemperatureAlertLevel.level(for: 96, isEnabled: false), .none)
        XCTAssertEqual(TemperatureAlertLevel.level(for: nil, isEnabled: true), .none)
    }

    func testAlertLevelUsesOrangeThenRedThresholds() {
        XCTAssertEqual(TemperatureAlertLevel.level(for: 80, isEnabled: true), .elevated)
        XCTAssertEqual(TemperatureAlertLevel.level(for: 94.9, isEnabled: true), .elevated)
        XCTAssertEqual(TemperatureAlertLevel.level(for: 95, isEnabled: true), .critical)
    }

    func testStoreAlertLevelFollowsToggle() {
        let settings = FakeTemperatureSettingsStore()
        settings.isHighTemperatureAlertEnabled = true
        let store = TemperatureStore(
            reader: FakeTemperatureReader(celsius: 96),
            settingsStore: settings
        )

        store.refresh()
        XCTAssertEqual(store.alertLevel, .critical)

        store.isHighTemperatureAlertEnabled = false
        XCTAssertEqual(store.alertLevel, .none)
        XCTAssertFalse(settings.isHighTemperatureAlertEnabled)
    }

    func testRanksHeavyProcessesByCPUThenMemoryAndExcludesSelf() {
        let earlier = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 11)
        let ranked = HeavyProcessAggregator.ranked(
            current: [
                makeSnapshot(pid: 10, name: "self", cpuTime: 5, memoryBytes: 99, sampledAt: now),
                makeSnapshot(pid: 21, name: "hot", cpuTime: 1.4, memoryBytes: 8, sampledAt: now),
                makeSnapshot(pid: 22, name: "warm", cpuTime: 1.1, memoryBytes: 32, sampledAt: now),
                makeSnapshot(pid: 23, name: "idle-big", cpuTime: 1.0, memoryBytes: 64, sampledAt: now),
                makeSnapshot(pid: 1, name: "kernel", cpuTime: 9, memoryBytes: 1, sampledAt: now)
            ],
            previous: [
                ProcessIdentity(pid: 10, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(pid: 10, name: "self", cpuTime: 4, memoryBytes: 99, sampledAt: earlier),
                ProcessIdentity(pid: 21, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(pid: 21, name: "hot", cpuTime: 1.0, memoryBytes: 8, sampledAt: earlier),
                ProcessIdentity(pid: 22, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(pid: 22, name: "warm", cpuTime: 1.0, memoryBytes: 32, sampledAt: earlier),
                ProcessIdentity(pid: 23, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(pid: 23, name: "idle-big", cpuTime: 1.0, memoryBytes: 64, sampledAt: earlier)
            ],
            history: [:],
            excludingPID: 10,
            now: now
        ).processes

        XCTAssertEqual(ranked.map(\.name), ["hot", "warm", "idle-big"])
        XCTAssertEqual(ranked[0].cpuPercent, 40, accuracy: 0.01)
        XCTAssertEqual(ranked[1].cpuPercent, 10, accuracy: 0.01)
        XCTAssertEqual(ranked[2].cpuPercent, 0, accuracy: 0.01)
    }

    func testGroupsChromeHelpersAndAveragesCPUOver15Seconds() {
        XCTAssertEqual(
            HeavyProcessAggregator.applicationGroup(
                name: "Google Chrome Helper (GPU)",
                executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
            ),
            "Google Chrome"
        )

        let t0 = Date(timeIntervalSince1970: 10)
        let t1 = Date(timeIntervalSince1970: 12)
        let t2 = Date(timeIntervalSince1970: 14)
        let previous: [ProcessIdentity: ProcessResourceSnapshot] = [
            ProcessIdentity(pid: 21, startTime: Date(timeIntervalSince1970: 1)):
                makeSnapshot(
                    pid: 21,
                    name: "Google Chrome",
                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    cpuTime: 1.0,
                    memoryBytes: 100,
                    sampledAt: t0
                ),
            ProcessIdentity(pid: 22, startTime: Date(timeIntervalSince1970: 1)):
                makeSnapshot(
                    pid: 22,
                    name: "Google Chrome Helper",
                    executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                    cpuTime: 1.0,
                    memoryBytes: 50,
                    sampledAt: t0
                )
        ]

        let first = HeavyProcessAggregator.ranked(
            current: [
                makeSnapshot(
                    pid: 21,
                    name: "Google Chrome",
                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    cpuTime: 1.4,
                    memoryBytes: 100,
                    sampledAt: t1
                ),
                makeSnapshot(
                    pid: 22,
                    name: "Google Chrome Helper",
                    executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                    cpuTime: 1.2,
                    memoryBytes: 50,
                    sampledAt: t1
                )
            ],
            previous: previous,
            history: [:],
            excludingPID: 10,
            now: t1
        )
        XCTAssertEqual(first.processes.map(\.name), ["Google Chrome"])
        XCTAssertEqual(first.processes[0].processCount, 2)
        XCTAssertEqual(first.processes[0].cpuPercent, 30, accuracy: 0.01)
        XCTAssertEqual(first.processes[0].memoryBytes, 150)

        let second = HeavyProcessAggregator.ranked(
            current: [
                makeSnapshot(
                    pid: 21,
                    name: "Google Chrome",
                    executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    cpuTime: 1.42,
                    memoryBytes: 100,
                    sampledAt: t2
                ),
                makeSnapshot(
                    pid: 22,
                    name: "Google Chrome Helper",
                    executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                    cpuTime: 1.22,
                    memoryBytes: 50,
                    sampledAt: t2
                )
            ],
            previous: [
                ProcessIdentity(pid: 21, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(
                        pid: 21,
                        name: "Google Chrome",
                        executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                        cpuTime: 1.4,
                        memoryBytes: 100,
                        sampledAt: t1
                    ),
                ProcessIdentity(pid: 22, startTime: Date(timeIntervalSince1970: 1)):
                    makeSnapshot(
                        pid: 22,
                        name: "Google Chrome Helper",
                        executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                        cpuTime: 1.2,
                        memoryBytes: 50,
                        sampledAt: t1
                    )
            ],
            history: first.history,
            excludingPID: 10,
            now: t2
        )
        XCTAssertEqual(second.processes[0].cpuPercent, 16, accuracy: 0.01)
    }

    func testTerminatorRefusesToSignalSelfOrReusedPID() async {
        let process = HeavyProcess(
            name: "worker",
            executablePath: "/tmp/worker",
            members: [ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1))],
            cpuPercent: 40,
            memoryBytes: 8
        )
        let replacement = MonitoredProcess(
            id: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 2)),
            ownerUID: 501,
            executablePath: "/tmp/worker",
            arguments: [],
            workingDirectory: nil,
            memoryBytes: 8
        )
        let signaler = RecordingHeavyProcessSignaler()
        let terminator = HeavyProcessTerminator(
            ownerUID: 501,
            processCollector: StaticProcessCollector(process: replacement),
            processSignaler: signaler,
            waitTimeout: 0.01,
            selfPID: 99
        )

        let outcome = await terminator.terminate(process)

        guard case .failed = outcome else {
            return XCTFail("Expected reused PID to be rejected")
        }
        XCTAssertTrue(signaler.signals.isEmpty)
    }

    private func makeSnapshot(
        pid: Int32,
        name: String,
        executablePath: String? = nil,
        cpuTime: TimeInterval,
        memoryBytes: UInt64,
        sampledAt: Date
    ) -> ProcessResourceSnapshot {
        ProcessResourceSnapshot(
            pid: pid,
            startTime: Date(timeIntervalSince1970: 1),
            ownerUID: 501,
            name: name,
            executablePath: executablePath ?? "/tmp/\(name)",
            cpuTime: cpuTime,
            memoryBytes: memoryBytes,
            sampledAt: sampledAt
        )
    }
}

@MainActor
private final class FakeTemperatureSettingsStore: TemperatureSettingsStoring {
    var isHighTemperatureAlertEnabled = true
}

@MainActor
private final class FakeTemperatureReader: TemperatureReading {
    var celsius: Double?

    init(celsius: Double?) {
        self.celsius = celsius
    }

    func readCelsius() -> Double? {
        celsius
    }
}

private struct StaticProcessCollector: ProcessCollecting {
    let process: MonitoredProcess?

    func collect(pid: Int32) -> MonitoredProcess? {
        guard process?.id.pid == pid else { return nil }
        return process
    }
}

private final class RecordingHeavyProcessSignaler: ProcessSignaling, @unchecked Sendable {
    private(set) var signals: [Int32] = []

    func send(signal: Int32, to pid: Int32) throws {
        signals.append(signal)
    }
}
