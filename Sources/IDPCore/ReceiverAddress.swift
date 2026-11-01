import Foundation
import IDPProtocol

/// A receiver as the user types it: hostname, IPv4 or IPv6 literal, with an
/// optional port (`host:port`, `[v6]:port`).
public struct ReceiverAddress: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = defaultPort) {
        self.host = host
        self.port = port
    }

    /// Parses `text`; a port inside it wins over `defaultPort`. Returns nil
    /// for empty input or a bad port.
    public static func parse(_ text: String, defaultPort: UInt16 = IDPProtocol.defaultPort) -> ReceiverAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { return ReceiverAddress(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()) else { return nil }
            return ReceiverAddress(host: host, port: port)
        }

        let colons = trimmed.filter { $0 == ":" }.count
        if colons == 1, let separator = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<separator])
            guard !host.isEmpty, let port = parsePort(trimmed[trimmed.index(after: separator)...]) else { return nil }
            return ReceiverAddress(host: host, port: port)
        }
        // No colon, or a bare IPv6 literal.
        return ReceiverAddress(host: trimmed, port: defaultPort)
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func parsePort<S: StringProtocol>(_ text: S) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}

/// `--host <h> [--port <p>]` launch arguments, so scripted installs can
/// auto-connect at start.
public struct LaunchOptions: Equatable, Sendable {
    public var address: ReceiverAddress?

    public init(address: ReceiverAddress? = nil) {
        self.address = address
    }

    /// Unknown arguments (e.g. ones AppKit adds) are ignored.
    public static func parse(_ arguments: [String]) -> LaunchOptions {
        var host: String?
        var port: UInt16?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index) < arguments.endIndex ? arguments[arguments.index(after: index)] : nil
            switch argument {
            case "--host":
                host = next
                index += 1
            case "--port":
                port = next.flatMap(UInt16.init)
                index += 1
            default:
                break
            }
            index += 1
        }
        guard let host, var address = ReceiverAddress.parse(host) else { return LaunchOptions() }
        if let port { address.port = port }
        return LaunchOptions(address: address)
    }
}
