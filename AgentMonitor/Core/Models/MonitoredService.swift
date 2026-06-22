import Foundation

struct MonitoredService: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case localProject
        case launchAgent
        case userProcess
    }

    let id: String
    let displayName: String
    let kind: Kind
    let projectRoot: URL?
    let launchAgentLabel: String?
    let processes: [MonitoredProcess]
    let endpoints: [ListeningEndpoint]

    var memoryBytes: UInt64 {
        processes.reduce(0) { $0 + $1.memoryBytes }
    }
}
