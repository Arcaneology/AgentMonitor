import XCTest
@testable import AgentMonitor

final class LsofFieldParserTests: XCTestCase {
    private let parser = LsofFieldParser()

    func testParsesIPv4TCPListener() {
        let records = parser.parse(fixture(
            "p42", "cnode", "u501",
            "\nf12", "tIPv4", "PTCP", "n127.0.0.1:3000", "TST=LISTEN"
        ))

        XCTAssertEqual(records, [
            PortRecord(
                pid: 42,
                ownerUID: 501,
                command: "node",
                endpoint: ListeningEndpoint(
                    address: "127.0.0.1",
                    port: 3000,
                    transport: .tcp
                )
            )
        ])
    }

    func testParsesBracketedIPv6TCPListener() {
        let records = parser.parse(fixture(
            "p84", "cvite", "u501",
            "\nf18", "tIPv6", "PTCP", "n[::1]:5173", "TST=LISTEN"
        ))

        XCTAssertEqual(records.first?.endpoint, ListeningEndpoint(
            address: "::1",
            port: 5173,
            transport: .tcp
        ))
    }

    func testParsesUDPAndKeepsOnlyLocalEndpoint() {
        let records = parser.parse(fixture(
            "p73", "cpython3", "u501",
            "\nf7", "tIPv4", "PUDP", "n192.168.1.20:5353->224.0.0.251:5353"
        ))

        XCTAssertEqual(records.first?.endpoint, ListeningEndpoint(
            address: "192.168.1.20",
            port: 5353,
            transport: .udp
        ))
    }

    func testParsesMultipleFilesAndProcesses() {
        let records = parser.parse(fixture(
            "p10", "cnode", "u501",
            "\nf3", "PTCP", "n*:3000", "TST=LISTEN",
            "\nf4", "PTCP", "n*:3001", "TST=LISTEN",
            "\np20", "cgo", "u501",
            "\nf5", "PTCP", "n127.0.0.1:8080", "TST=LISTEN"
        ))

        XCTAssertEqual(records.map(\.pid), [10, 10, 20])
        XCTAssertEqual(records.map(\.endpoint.port), [3000, 3001, 8080])
    }

    func testIgnoresTCPConnectionsThatAreNotListening() {
        let records = parser.parse(fixture(
            "p42", "cnode", "u501",
            "\nf12", "PTCP", "n127.0.0.1:3000->127.0.0.1:51000", "TST=ESTABLISHED"
        ))

        XCTAssertTrue(records.isEmpty)
    }

    func testIgnoresRecordsWithMissingRequiredFields() {
        let records = parser.parse(fixture(
            "p10", "cnode",
            "\nf3", "PTCP", "n*:3000", "TST=LISTEN",
            "\np20", "cnode", "u501",
            "\nf4", "n*:3001", "TST=LISTEN",
            "\np30", "cnode", "u501",
            "\nf5", "PTCP", "TST=LISTEN"
        ))

        XCTAssertTrue(records.isEmpty)
    }

    func testIncompleteProcessDoesNotContaminateNextProcess() {
        let records = parser.parse(fixture(
            "p10", "cnode", "u501",
            "\nf3", "PTCP",
            "\np20", "cpython3", "u502",
            "\nf4", "PTCP", "n*:8000", "TST=LISTEN"
        ))

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.pid, 20)
        XCTAssertEqual(records.first?.ownerUID, 502)
    }

    func testEmptyOutputProducesNoRecords() {
        XCTAssertTrue(parser.parse(Data()).isEmpty)
    }

    private func fixture(_ fields: String...) -> Data {
        Data((fields.joined(separator: "\0") + "\0").utf8)
    }
}

