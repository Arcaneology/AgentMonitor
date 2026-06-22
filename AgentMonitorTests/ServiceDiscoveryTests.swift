import XCTest
@testable import AgentMonitor

final class ServiceDiscoveryTests: XCTestCase {
    func testGroupsProcessesAndPortsByProject() throws {
        let root = try makeProject(named: "web-console")
        defer { try? FileManager.default.removeItem(at: root) }
        let processes: [Int32: MonitoredProcess] = [
            10: makeProcess(pid: 10, workingDirectory: root, memory: 100),
            20: makeProcess(pid: 20, workingDirectory: root, memory: 200)
        ]
        let ports = [
            makePort(pid: 20, port: 4000),
            makePort(pid: 10, port: 3000),
            makePort(pid: 10, port: 3001)
        ]

        let services = ServiceGrouper(projectResolver: ProjectResolver()).group(
            portRecords: ports,
            processes: processes,
            launchAgents: []
        )

        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(service.displayName, "web-console")
        XCTAssertEqual(service.kind, .localProject)
        XCTAssertEqual(service.processes.map(\.id.pid), [10, 20])
        XCTAssertEqual(service.endpoints.map(\.port), [3000, 3001, 4000])
        XCTAssertEqual(service.memoryBytes, 300)
    }

    func testLaunchAgentTakesPriorityAndAppearsWithoutPort() throws {
        let process = makeProcess(pid: 30, workingDirectory: nil, memory: 50)
        let agent = LaunchAgentInfo(
            label: "com.example.worker",
            pid: 30,
            plistURL: URL(fileURLWithPath: "/tmp/worker.plist"),
            program: "/usr/bin/worker",
            arguments: []
        )

        let services = ServiceGrouper(projectResolver: ProjectResolver()).group(
            portRecords: [],
            processes: [30: process],
            launchAgents: [agent]
        )

        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service.kind, .launchAgent)
        XCTAssertEqual(service.displayName, "com.example.worker")
        XCTAssertEqual(service.launchAgentLabel, "com.example.worker")
        XCTAssertTrue(service.endpoints.isEmpty)
    }

    func testDiscoveryKeepsPortResultsWhenLaunchAgentCollectionFails() async throws {
        let process = makeProcess(pid: 40, workingDirectory: nil, memory: 75)
        let engine = DiscoveryEngine(
            portCollector: StubPortCollector(records: [makePort(pid: 40, port: 8080)]),
            processCollector: StubProcessCollector(processes: [40: process]),
            launchAgentCollector: FailingLaunchAgentCollector(),
            serviceGrouper: ServiceGrouper(projectResolver: ProjectResolver())
        )

        let snapshot = await engine.discover()

        XCTAssertEqual(snapshot.services.count, 1)
        XCTAssertEqual(snapshot.services.first?.endpoints.first?.port, 8080)
        XCTAssertEqual(snapshot.issues.map(\.source), [.launchAgents])
    }

    private func makeProject(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"name\":\"\(name)\"}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        return root
    }
}

private func makeProcess(
    pid: Int32,
    workingDirectory: URL?,
    memory: UInt64
) -> MonitoredProcess {
    MonitoredProcess(
        id: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: TimeInterval(pid))),
        ownerUID: 501,
        executablePath: "/usr/bin/node",
        arguments: [],
        workingDirectory: workingDirectory,
        memoryBytes: memory
    )
}

private func makePort(pid: Int32, port: UInt16) -> PortRecord {
    PortRecord(
        pid: pid,
        ownerUID: 501,
        command: "node",
        endpoint: ListeningEndpoint(address: "127.0.0.1", port: port, transport: .tcp)
    )
}

private struct StubPortCollector: PortCollecting {
    let records: [PortRecord]

    func collect() async throws -> [PortRecord] {
        records
    }
}

private struct StubProcessCollector: ProcessCollecting {
    let processes: [Int32: MonitoredProcess]

    func collect(pid: Int32) -> MonitoredProcess? {
        processes[pid]
    }
}

private struct FailingLaunchAgentCollector: LaunchAgentCollecting {
    struct Failure: Error {}

    func collect() async throws -> [LaunchAgentInfo] {
        throw Failure()
    }
}
