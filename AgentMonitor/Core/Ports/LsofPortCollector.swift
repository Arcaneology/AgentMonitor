import Foundation

struct LsofPortCollector: PortCollecting {
    enum Error: Swift.Error, Equatable, Sendable {
        case commandFailed(status: Int32, message: String)
    }

    private let ownerUID: UInt32
    private let commandRunner: any CommandRunning
    private let parser = LsofFieldParser()

    init(ownerUID: UInt32, commandRunner: any CommandRunning) {
        self.ownerUID = ownerUID
        self.commandRunner = commandRunner
    }

    func collect() async throws -> [PortRecord] {
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-w", "-a", "-u", String(ownerUID),
                "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcufPnT0"
            ],
            timeout: 2
        )

        if result.terminationStatus == 1 && result.standardOutput.isEmpty {
            return []
        }

        guard result.terminationStatus == 0 else {
            throw Error.commandFailed(
                status: result.terminationStatus,
                message: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return parser.parse(result.standardOutput)
            .filter { $0.ownerUID == ownerUID }
    }
}

