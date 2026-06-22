import Foundation

struct LsofFieldParser: Sendable {
    func parse(_ data: Data) -> [PortRecord] {
        var records: [PortRecord] = []
        var process: ProcessFields?
        var file: FileFields?

        func appendCurrentFile() {
            guard
                let process,
                let pid = process.pid,
                let ownerUID = process.ownerUID,
                let file,
                let transport = file.transport,
                let name = file.name,
                transport != .tcp || file.state == "LISTEN",
                let endpoint = parseEndpoint(name, transport: transport)
            else {
                return
            }

            records.append(PortRecord(
                pid: pid,
                ownerUID: ownerUID,
                command: process.command,
                endpoint: endpoint
            ))
        }

        for rawField in data.split(separator: 0, omittingEmptySubsequences: true) {
            var bytes = rawField[...]
            while bytes.first == 10 || bytes.first == 13 {
                bytes = bytes.dropFirst()
            }

            guard
                let identifier = bytes.first,
                let value = String(bytes: bytes.dropFirst(), encoding: .utf8)
            else {
                continue
            }

            switch identifier {
            case Character("p").asciiValue:
                appendCurrentFile()
                file = nil
                process = ProcessFields(pid: Int32(value))

            case Character("c").asciiValue:
                process?.command = value

            case Character("u").asciiValue:
                process?.ownerUID = UInt32(value)

            case Character("f").asciiValue:
                appendCurrentFile()
                file = FileFields()

            case Character("P").asciiValue:
                file?.transport = ListeningEndpoint.Transport(rawValue: value.lowercased())

            case Character("n").asciiValue:
                file?.name = value

            case Character("T").asciiValue where value.hasPrefix("ST="):
                file?.state = String(value.dropFirst(3)).uppercased()

            default:
                continue
            }
        }

        appendCurrentFile()
        return records
    }

    private func parseEndpoint(
        _ name: String,
        transport: ListeningEndpoint.Transport
    ) -> ListeningEndpoint? {
        let localName = name.split(separator: "->", maxSplits: 1).first ?? Substring(name)
        let address: String
        let portText: Substring

        if localName.first == "[" {
            guard
                let closingBracket = localName.firstIndex(of: "]"),
                localName.index(after: closingBracket) < localName.endIndex,
                localName[localName.index(after: closingBracket)] == ":"
            else {
                return nil
            }

            address = String(localName[localName.index(after: localName.startIndex)..<closingBracket])
            portText = localName[localName.index(closingBracket, offsetBy: 2)...]
        } else {
            guard let separator = localName.lastIndex(of: ":") else {
                return nil
            }

            address = String(localName[..<separator])
            portText = localName[localName.index(after: separator)...]
        }

        guard let port = UInt16(portText) else {
            return nil
        }

        return ListeningEndpoint(
            address: address.isEmpty ? "*" : address,
            port: port,
            transport: transport
        )
    }
}

private struct ProcessFields {
    var pid: Int32?
    var ownerUID: UInt32?
    var command: String?
}

private struct FileFields {
    var transport: ListeningEndpoint.Transport?
    var name: String?
    var state: String?
}

