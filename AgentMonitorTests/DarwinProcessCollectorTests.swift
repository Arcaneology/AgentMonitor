import Darwin
import XCTest
@testable import AgentMonitor

final class DarwinProcessCollectorTests: XCTestCase {
    func testCollectsCurrentProcessDetails() throws {
        let collector = DarwinProcessCollector(ownerUID: getuid())

        let process = try XCTUnwrap(collector.collect(pid: getpid()))

        XCTAssertEqual(process.id.pid, getpid())
        XCTAssertEqual(process.ownerUID, getuid())
        XCTAssertFalse(process.executablePath.isEmpty)
        XCTAssertNotNil(process.workingDirectory)
        XCTAssertGreaterThan(process.memoryBytes, 0)
    }

    func testRejectsProcessOwnedByDifferentUser() {
        let collector = DarwinProcessCollector(ownerUID: getuid() + 1)

        XCTAssertNil(collector.collect(pid: getpid()))
    }
}

