import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTime: Date
}

struct MonitoredProcess: Identifiable, Hashable, Sendable {
    let id: ProcessIdentity
    let ownerUID: UInt32
    let executablePath: String
    let arguments: [String]
    let workingDirectory: URL?
    let memoryBytes: UInt64
}
