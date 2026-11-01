import Foundation
import Network

/// What kind of link a connection runs over, for the menu and speed test results.
public enum LinkKind: String, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case thunderboltBridge = "Thunderbolt bridge"
    case loopback = "Loopback"
    case cellular = "Cellular"
    case other = "Other"

    /// `bridge*` interfaces are how macOS exposes Thunderbolt IP networking,
    /// so the name wins over the reported type (often `.other` or `.wiredEthernet`).
    public static func classify(interfaceName: String?, type: NWInterface.InterfaceType?) -> LinkKind {
        if let interfaceName, interfaceName.hasPrefix("bridge") { return .thunderboltBridge }
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .ethernet
        case .loopback: return .loopback
        case .cellular: return .cellular
        default: return .other
        }
    }
}

/// Interface and addresses of a live connection, from `NWConnection.currentPath`.
public struct LinkInfo: Equatable, Sendable {
    public var interfaceName: String?
    public var kind: LinkKind
    public var localAddress: String?
    public var remoteAddress: String?

    public init(interfaceName: String?, kind: LinkKind, localAddress: String?, remoteAddress: String?) {
        self.interfaceName = interfaceName
        self.kind = kind
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }

    public init(path: NWPath) {
        let interface = path.availableInterfaces.first
        self.init(
            interfaceName: interface?.name,
            kind: LinkKind.classify(interfaceName: interface?.name, type: interface?.type),
            localAddress: path.localEndpoint.map(Self.describe),
            remoteAddress: path.remoteEndpoint.map(Self.describe))
    }

    /// e.g. `bridge0 (Thunderbolt bridge)`.
    public var summary: String {
        guard let interfaceName else { return kind.rawValue }
        return "\(interfaceName) (\(kind.rawValue))"
    }

    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            switch host {
            case .ipv6(let address): return "[\(address)]:\(port)"
            default: return "\(host):\(port)"
            }
        default:
            return "\(endpoint)"
        }
    }
}
