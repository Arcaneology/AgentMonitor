import Darwin
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

    func testUsesExecutableNameInsteadOfEscapedLsofCommand() throws {
        let process = MonitoredProcess(
            id: ProcessIdentity(pid: 50, startTime: Date(timeIntervalSince1970: 50)),
            ownerUID: 501,
            executablePath: "/Applications/企业微信.app/Contents/MacOS/企业微信",
            arguments: [],
            workingDirectory: nil,
            memoryBytes: 100
        )
        let port = PortRecord(
            pid: 50,
            ownerUID: 501,
            command: "\\xe4\\xbc\\x81\\xe4\\xb8\\x9a\\xe5\\xbe\\xae\\xe4\\xbf\\xa1",
            endpoint: ListeningEndpoint(address: "127.0.0.1", port: 9000, transport: .tcp)
        )

        let services = ServiceGrouper(projectResolver: ProjectResolver()).group(
            portRecords: [port],
            processes: [50: process],
            launchAgents: []
        )

        XCTAssertEqual(services.first?.displayName, "企业微信")
    }

    func testDiscoversRunningLocalWebProject() async throws {
        let root = try makeProject(named: "local-integration-project")
        defer { try? FileManager.default.removeItem(at: root) }
        let portFile = root.appendingPathComponent("server-port.txt")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [
            "-c",
            "import socket,sys,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); open(sys.argv[1],'w').write(str(s.getsockname()[1])); time.sleep(10)",
            portFile.path
        ]
        server.currentDirectoryURL = root
        try server.run()
        defer {
            if server.isRunning {
                server.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let portText = try String(contentsOf: portFile, encoding: .utf8)
        let port = try XCTUnwrap(UInt16(portText))
        let ownerUID = getuid()
        let commandRunner = SystemCommandRunner()
        let engine = DiscoveryEngine(
            portCollector: LsofPortCollector(ownerUID: ownerUID, commandRunner: commandRunner),
            processCollector: DarwinProcessCollector(ownerUID: ownerUID),
            launchAgentCollector: EmptyLaunchAgentCollector(),
            serviceGrouper: ServiceGrouper(projectResolver: ProjectResolver())
        )

        let snapshot = await engine.discover()
        let service = try XCTUnwrap(
            snapshot.services.first { $0.displayName == "local-integration-project" }
        )

        XCTAssertEqual(service.kind, .localProject)
        XCTAssertEqual(service.processes.map(\.id.pid), [server.processIdentifier])
        XCTAssertTrue(service.endpoints.contains { $0.port == port })
    }

    private func makeProject(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"name\":\"\(name)\"}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        return root
    }

    // MARK: - Endpoint links

    func testLocalServiceURLBuildsBrowserLinksForTCPEndpoints() {
        XCTAssertEqual(
            ListeningEndpoint(address: "127.0.0.1", port: 3_000, transport: .tcp).localServiceURL?.absoluteString,
            "http://127.0.0.1:3000"
        )
        XCTAssertEqual(
            ListeningEndpoint(address: "*", port: 5_174, transport: .tcp).localServiceURL?.absoluteString,
            "http://localhost:5174",
            "A wildcard bind is reachable through localhost"
        )
        XCTAssertEqual(
            ListeningEndpoint(address: "0.0.0.0", port: 80, transport: .tcp).localServiceURL?.absoluteString,
            "http://localhost:80"
        )
        XCTAssertEqual(
            ListeningEndpoint(address: "::1", port: 4_321, transport: .tcp).localServiceURL?.absoluteString,
            "http://[::1]:4321",
            "IPv6 literals need brackets in a URL"
        )
    }

    func testLocalServiceURLStaysNilForUDPEndpoints() {
        XCTAssertNil(
            ListeningEndpoint(address: "127.0.0.1", port: 5_353, transport: .udp).localServiceURL,
            "A browser cannot open a UDP endpoint"
        )
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

private struct EmptyLaunchAgentCollector: LaunchAgentCollecting {
    func collect() async throws -> [LaunchAgentInfo] {
        []
    }
}
