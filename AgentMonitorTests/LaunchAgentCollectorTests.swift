import XCTest
@testable import AgentMonitor

final class LaunchAgentCollectorTests: XCTestCase {
    func testReturnsRunningAgentsFromConfiguredDirectory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writePlist(
            label: "com.example.server",
            programArguments: ["/usr/bin/python3", "server.py"],
            to: directory.appendingPathComponent("server.plist")
        )
        try Data("not a plist".utf8).write(to: directory.appendingPathComponent("invalid.plist"))

        let launchctlOutput = """
        PID\tStatus\tLabel
        123\t0\tcom.example.server
        -\t0\tcom.example.idle

        """
        let collector = LaunchAgentCollector(
            directoryURL: directory,
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: Data(launchctlOutput.utf8),
                standardError: Data()
            ))
        )

        let agents = try await collector.collect()

        XCTAssertEqual(agents, [LaunchAgentInfo(
            label: "com.example.server",
            pid: 123,
            plistURL: directory.appendingPathComponent("server.plist").resolvingSymlinksInPath(),
            program: "/usr/bin/python3",
            arguments: ["server.py"]
        )])
    }

    func testCommandFailureThrows() async {
        let collector = LaunchAgentCollector(
            directoryURL: URL(fileURLWithPath: "/tmp/unused"),
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data("launchctl failed".utf8)
            ))
        )

        do {
            _ = try await collector.collect()
            XCTFail("Expected collection to fail")
        } catch let error as LaunchAgentCollector.Error {
            XCTAssertEqual(error, .commandFailed(status: 1, message: "launchctl failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePlist(
        label: String,
        programArguments: [String],
        to url: URL
    ) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label,
                "ProgramArguments": programArguments
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}

struct StubCommandRunner: CommandRunning {
    let result: CommandResult

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        result
    }
}
