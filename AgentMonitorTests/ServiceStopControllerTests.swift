import Darwin
import XCTest
@testable import AgentMonitor

final class ServiceStopControllerTests: XCTestCase {
    func testRefusesToSignalWhenProcessIdentityChanged() async {
        let expected = makeStoppedProcess(pid: 100, startTime: 1)
        let replacement = makeStoppedProcess(pid: 100, startTime: 2)
        let table = MutableProcessTable(processes: [100: replacement])
        let signaler = RecordingProcessSignaler(table: table, removeOnSignals: [])
        let controller = makeController(table: table, signaler: signaler)

        let outcome = await controller.stop(makeService(processes: [expected]))

        guard case .failed = outcome else {
            return XCTFail("Expected identity validation to fail")
        }
        XCTAssertTrue(signaler.recordedSignals.isEmpty)
    }

    func testRequiresForceThenKillsStillRunningProcess() async {
        let process = makeStoppedProcess(pid: 101, startTime: 1)
        let table = MutableProcessTable(processes: [101: process])
        let signaler = RecordingProcessSignaler(table: table, removeOnSignals: [SIGKILL])
        let controller = makeController(table: table, signaler: signaler)
        let service = makeService(processes: [process])

        let gracefulOutcome = await controller.stop(service)
        XCTAssertEqual(gracefulOutcome, .requiresForce([101]))

        let forceOutcome = await controller.forceStop(service)
        XCTAssertEqual(forceOutcome, .stopped)
        XCTAssertEqual(signaler.recordedSignals.map(\.signal), [SIGTERM, SIGKILL])
    }

    func testLaunchAgentUsesBootoutTarget() async {
        let process = makeStoppedProcess(pid: 102, startTime: 1)
        let table = MutableProcessTable(processes: [102: process])
        let runner = RecordingCommandRunner()
        let controller = ServiceStopController(
            ownerUID: 501,
            processCollector: TableProcessCollector(table: table),
            processSignaler: RecordingProcessSignaler(table: table, removeOnSignals: []),
            commandRunner: runner,
            waitTimeout: 0.01
        )
        let service = makeService(
            processes: [process],
            kind: .launchAgent,
            launchAgentLabel: "com.example.worker"
        )

        _ = await controller.stop(service)
        let invocation = await runner.lastInvocation

        XCTAssertEqual(invocation?.executableURL.path, "/bin/launchctl")
        XCTAssertEqual(invocation?.arguments, ["bootout", "gui/501/com.example.worker"])
    }

    func testStopsOnlyControlledChildProcess() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
        }

        let processCollector = DarwinProcessCollector(ownerUID: getuid())
        var monitoredProcess: MonitoredProcess?
        for _ in 0..<20 where monitoredProcess == nil {
            monitoredProcess = processCollector.collect(pid: child.processIdentifier)
            if monitoredProcess == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let process = try XCTUnwrap(monitoredProcess)
        let controller = ServiceStopController(
            ownerUID: getuid(),
            processCollector: processCollector,
            processSignaler: SystemProcessSignaler(),
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: Data(),
                standardError: Data()
            )),
            waitTimeout: 1
        )

        let outcome = await controller.stop(makeService(processes: [process]))

        XCTAssertEqual(outcome, .stopped)
        XCTAssertFalse(child.isRunning)
    }

    private func makeController(
        table: MutableProcessTable,
        signaler: RecordingProcessSignaler
    ) -> ServiceStopController {
        ServiceStopController(
            ownerUID: 501,
            processCollector: TableProcessCollector(table: table),
            processSignaler: signaler,
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: Data(),
                standardError: Data()
            )),
            waitTimeout: 0.01
        )
    }
}

private func makeStoppedProcess(pid: Int32, startTime: TimeInterval) -> MonitoredProcess {
    MonitoredProcess(
        id: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: startTime)),
        ownerUID: 501,
        executablePath: "/bin/sleep",
        arguments: [],
        workingDirectory: nil,
        memoryBytes: 1
    )
}

private func makeService(
    processes: [MonitoredProcess],
    kind: MonitoredService.Kind = .userProcess,
    launchAgentLabel: String? = nil
) -> MonitoredService {
    MonitoredService(
        id: "test-service",
        displayName: "Test Service",
        kind: kind,
        projectRoot: nil,
        launchAgentLabel: launchAgentLabel,
        processes: processes,
        endpoints: []
    )
}

private final class MutableProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: MonitoredProcess]

    init(processes: [Int32: MonitoredProcess]) {
        self.processes = processes
    }

    func process(pid: Int32) -> MonitoredProcess? {
        lock.lock()
        defer { lock.unlock() }
        return processes[pid]
    }

    func remove(pid: Int32) {
        lock.lock()
        processes[pid] = nil
        lock.unlock()
    }
}

private struct TableProcessCollector: ProcessCollecting {
    let table: MutableProcessTable

    func collect(pid: Int32) -> MonitoredProcess? {
        table.process(pid: pid)
    }
}

private final class RecordingProcessSignaler: ProcessSignaling, @unchecked Sendable {
    struct Record: Equatable {
        let signal: Int32
        let pid: Int32
    }

    private let lock = NSLock()
    private let table: MutableProcessTable
    private let removeOnSignals: Set<Int32>
    private var records: [Record] = []

    init(table: MutableProcessTable, removeOnSignals: Set<Int32>) {
        self.table = table
        self.removeOnSignals = removeOnSignals
    }

    var recordedSignals: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func send(signal: Int32, to pid: Int32) throws {
        lock.lock()
        records.append(Record(signal: signal, pid: pid))
        lock.unlock()

        if removeOnSignals.contains(signal) {
            table.remove(pid: pid)
        }
    }
}

private actor RecordingCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    private(set) var lastInvocation: Invocation?

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        lastInvocation = Invocation(executableURL: executableURL, arguments: arguments)
        return CommandResult(
            terminationStatus: 0,
            standardOutput: Data(),
            standardError: Data()
        )
    }
}

