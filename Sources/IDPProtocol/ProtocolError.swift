import Foundation

/// A malformed message (§9). Detecting one means: send GOODBYE PROTOCOL_ERROR
/// (VERSION_MISMATCH for `.versionMismatch`) and close.
public enum ProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Header `length` above 64 MiB.
    case payloadTooLarge(UInt32)
    /// Payload ended before a field was complete.
    case truncated
    /// A fixed-size payload (or a variable one with trailing bytes) has the wrong length.
    case wrongPayloadLength(type: UInt8, expected: Int, actual: Int)
    /// A `string` claims more bytes than the payload holds.
    case stringOverflow
    /// HELLO from a peer speaking another `protocol_version`. Detected before
    /// the v1 layout is applied, since other versions may lay HELLO out
    /// differently. Answer with GOODBYE VERSION_MISMATCH, not PROTOCOL_ERROR (§3, §9).
    case versionMismatch(UInt16)

    public var description: String {
        switch self {
        case .payloadTooLarge(let length):
            return "payload length \(length) exceeds 64 MiB"
        case .truncated:
            return "payload truncated"
        case .wrongPayloadLength(let type, let expected, let actual):
            return String(format: "type 0x%02X: payload is %d bytes, expected %d", type, actual, expected)
        case .stringOverflow:
            return "string extends past the payload"
        case .versionMismatch(let version):
            return "peer speaks protocol v\(version), we speak v\(protocolVersion)"
        }
    }
}
