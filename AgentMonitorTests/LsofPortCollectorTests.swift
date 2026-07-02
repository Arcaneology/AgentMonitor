import XCTest
@testable import AgentMonitor

final class LsofPortCollectorTests: XCTestCase {
    func testReturnsOnlyRecordsOwnedByConfiguredUser() async throws {
        let output = fixture(
            "p10", "cnode", "u501",
            "\nf3", "PTCP", "n*:3000", "TST=LISTEN",
            "\np20", "cnode", "u502",
            "\nf4", "PTCP", "n*:4000", "TST=LISTEN"
        )
        let collector = LsofPortCollector(
            ownerUID: 501,
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 0,
                standardOutput: output,
                standardError: Data()
            ))
        )

        let records = try await collector.collect()

        XCTAssertEqual(records.map(\.pid), [10])
    }

    func testExitStatusOneWithEmptyOutputMeansNoListeners() async throws {
        let collector = LsofPortCollector(
            ownerUID: 501,
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            ))
        )

        let records = try await collector.collect()

        XCTAssertTrue(records.isEmpty)
    }

    func testOtherExitStatusThrows() async {
        let collector = LsofPortCollector(
            ownerUID: 501,
            commandRunner: StubCommandRunner(result: CommandResult(
                terminationStatus: 2,
                standardOutput: Data(),
                standardError: Data("failed".utf8)
            ))
        )

        do {
            _ = try await collector.collect()
            XCTFail("Expected collection to fail")
        } catch let error as LsofPortCollector.Error {
            XCTAssertEqual(error, .commandFailed(status: 2, message: "failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUsesTolerantCommandTimeout() async throws {
        let commandRunner = TimeoutRecordingCommandRunner(result: CommandResult(
            terminationStatus: 1,
            standardOutput: Data(),
            standardError: Data()
        ))
        let collector = LsofPortCollector(
            ownerUID: 501,
            commandRunner: commandRunner
        )

        _ = try await collector.collect()

        let timeouts = await commandRunner.recordedTimeouts()
        XCTAssertEqual(timeouts, [5])
    }

    private func fixture(_ fields: String...) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }
}
