import Foundation

struct LaunchAgentInfo: Equatable, Sendable {
    let label: String
    let pid: Int32
    let plistURL: URL
    let program: String?
    let arguments: [String]
}

protocol LaunchAgentCollecting: Sendable {
    func collect() async throws -> [LaunchAgentInfo]
}

struct LaunchAgentCollector: LaunchAgentCollecting {
    enum Error: Swift.Error, Equatable, Sendable {
        case commandFailed(status: Int32, message: String)
    }

    private let directoryURL: URL
    private let commandRunner: any CommandRunning

    init(directoryURL: URL, commandRunner: any CommandRunning) {
        self.directoryURL = directoryURL
        self.commandRunner = commandRunner
    }

    func collect() async throws -> [LaunchAgentInfo] {
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["list"],
            timeout: 2
        )
        guard result.terminationStatus == 0 else {
            throw Error.commandFailed(
                status: result.terminationStatus,
                message: String(decoding: result.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let runningPIDs = parseRunningPIDs(result.standardOutput)
        return loadPlists().compactMap { plist in
            guard let pid = runningPIDs[plist.label] else { return nil }
            let program = plist.program ?? plist.programArguments.first
            let arguments = plist.program == nil
                ? Array(plist.programArguments.dropFirst())
                : plist.programArguments

            return LaunchAgentInfo(
                label: plist.label,
                pid: pid,
                plistURL: plist.url.resolvingSymlinksInPath(),
                program: program,
                arguments: arguments
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func parseRunningPIDs(_ data: Data) -> [String: Int32] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { result, line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard
                    columns.count >= 3,
                    let pid = Int32(columns[0]),
                    !columns[2].isEmpty
                else {
                    return
                }
                result[String(columns[2])] = pid
            }
    }

    private func loadPlists() -> [DecodedLaunchAgent] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "plist" }
            .compactMap { url in
                guard
                    let data = try? Data(contentsOf: url),
                    let plist = try? PropertyListDecoder().decode(LaunchAgentPlist.self, from: data),
                    !plist.label.isEmpty
                else {
                    return nil
                }
                return DecodedLaunchAgent(
                    label: plist.label,
                    url: url,
                    program: plist.program,
                    programArguments: plist.programArguments ?? []
                )
            }
    }
}

private struct LaunchAgentPlist: Decodable {
    let label: String
    let program: String?
    let programArguments: [String]?

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case program = "Program"
        case programArguments = "ProgramArguments"
    }
}

private struct DecodedLaunchAgent {
    let label: String
    let url: URL
    let program: String?
    let programArguments: [String]
}
