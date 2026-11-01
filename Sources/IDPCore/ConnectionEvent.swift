import Foundation
import IDPProtocol

/// What a `Connection` reports to its owner, always on the connection's queue.
public enum ConnectionEvent: Sendable {
    /// TCP is up; waiting for HELLO.
    case connected(LinkInfo)
    /// A valid v1 HELLO arrived (version and codec already checked).
    case hello(Hello)
    /// A message the connection does not handle itself, e.g. KEYFRAME_REQUEST or STATS.
    case message(Message)
    /// Link RTT (minimum of recent PINGs) changed.
    case rttUpdated(microseconds: UInt64)
    case linkChanged(LinkInfo)
    /// Terminal. No events follow.
    case closed(DisconnectReason)
}

/// Why a connection ended.
public enum DisconnectReason: Equatable, Sendable, CustomStringConvertible {
    /// We sent GOODBYE with this reason (user disconnect, local failure).
    case local(GoodbyeReason, String)
    case peerGoodbye(Goodbye)
    /// Nothing received for 2 s after HELLO (§6.5).
    case livenessTimeout
    /// No HELLO within 3 s of connecting (§7.3).
    case helloTimeout
    case protocolError(String)
    case versionMismatch(UInt16)
    case unsupportedCodec
    /// Connect failure, reset, EOF, …
    case network(String)

    /// Whether the session should try again with backoff. A user disconnect
    /// or an incompatible receiver is final.
    public var isRetryable: Bool {
        switch self {
        case .local(let reason, _): return reason != .normal && reason != .internalError
        case .versionMismatch, .unsupportedCodec: return false
        case .peerGoodbye(let goodbye):
            return goodbye.reason != .versionMismatch && goodbye.reason != .unsupportedCodec
        default: return true
        }
    }

    public var description: String {
        switch self {
        case .local(let reason, let message):
            return message.isEmpty ? "closed locally (\(reason))" : "closed locally (\(reason)): \(message)"
        case .peerGoodbye(let goodbye):
            return goodbye.message.isEmpty
                ? "receiver said goodbye (\(goodbye.reason))"
                : "receiver said goodbye (\(goodbye.reason)): \(goodbye.message)"
        case .livenessTimeout: return "receiver stopped responding"
        case .helloTimeout: return "no HELLO from receiver within 3 s"
        case .protocolError(let detail): return "protocol error: \(detail)"
        case .versionMismatch(let version): return "receiver speaks protocol v\(version), we speak v\(protocolVersion)"
        case .unsupportedCodec: return "receiver cannot decode HEVC Main"
        case .network(let detail): return detail
        }
    }
}
