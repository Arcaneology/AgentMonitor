import XCTest
@testable import AgentMonitor

final class SystemCommandRunnerTests: XCTestCase {
    func testCapturesStandardOutput() async throws {
        let result = try await SystemCommandRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["hello"],
            timeout: 1
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "hello")
    }

    func testTerminatesCommandAfterTimeout() async {
        do {
            _ = try await SystemCommandRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["1"],
                timeout: 0.05
            )
            XCTFail("Expected the command to time out")
        } catch let error as CommandExecutionError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunsRepeatedlyWithoutHanging() async throws {
        let runner = SystemCommandRunner()

        for index in 0..<20 {
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: [String(index)],
                timeout: 1
            )
            XCTAssertEqual(result.terminationStatus, 0)
        }
    }
}
