protocol PortCollecting: Sendable {
    func collect() async throws -> [PortRecord]
}

