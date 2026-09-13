import Foundation

struct ListeningEndpoint: Hashable, Sendable {
    enum Transport: String, Hashable, Sendable {
        case tcp
        case udp
    }

    let address: String
    let port: UInt16
    let transport: Transport

    /// Address a browser can actually reach. Wildcard binds are listening on
    /// every interface, so `localhost` is the useful spelling for them; IPv6
    /// literals need brackets inside a URL.
    var browserHost: String {
        switch address {
        case "*", "0.0.0.0", "::": "localhost"
        case "::1": "[::1]"
        default: address
        }
    }

    /// URL for opening this endpoint in a browser. Only TCP endpoints carry
    /// HTTP, so UDP endpoints deliberately return nil instead of a link that
    /// could not answer a request.
    var localServiceURL: URL? {
        guard transport == .tcp else { return nil }
        return URL(string: "http://\(browserHost):\(port)")
    }
}

struct PortRecord: Hashable, Sendable {
    let pid: Int32
    let ownerUID: UInt32
    let command: String?
    let endpoint: ListeningEndpoint
}
