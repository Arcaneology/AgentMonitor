struct ListeningEndpoint: Hashable, Sendable {
    enum Transport: String, Hashable, Sendable {
        case tcp
        case udp
    }

    let address: String
    let port: UInt16
    let transport: Transport
}

struct PortRecord: Hashable, Sendable {
    let pid: Int32
    let ownerUID: UInt32
    let command: String?
    let endpoint: ListeningEndpoint
}

