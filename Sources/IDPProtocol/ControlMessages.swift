import Foundation

/// GOODBYE reason codes (§6.6). A struct rather than an enum so a reason from
/// a newer peer still decodes.
public struct GoodbyeReason: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let normal = GoodbyeReason(rawValue: 0)
    public static let versionMismatch = GoodbyeReason(rawValue: 1)
    public static let busy = GoodbyeReason(rawValue: 2)
    public static let unsupportedCodec = GoodbyeReason(rawValue: 3)
    public static let timeout = GoodbyeReason(rawValue: 4)
    public static let protocolError = GoodbyeReason(rawValue: 5)
    public static let internalError = GoodbyeReason(rawValue: 6)

    public var description: String {
        switch self {
        case .normal: return "NORMAL"
        case .versionMismatch: return "VERSION_MISMATCH"
        case .busy: return "BUSY"
        case .unsupportedCodec: return "UNSUPPORTED_CODEC"
        case .timeout: return "TIMEOUT"
        case .protocolError: return "PROTOCOL_ERROR"
        case .internalError: return "INTERNAL_ERROR"
        default: return "reason \(rawValue)"
        }
    }
}

/// GOODBYE (0x05), both directions (§6.6).
public struct Goodbye: Equatable, Sendable {
    public var reason: GoodbyeReason
    public var message: String

    public init(reason: GoodbyeReason, message: String = "") {
        self.reason = reason
        self.message = message
    }

    init(reader: inout ByteReader) throws {
        reason = GoodbyeReason(rawValue: try reader.u16())
        message = try reader.string()
    }

    func write(to writer: inout ByteWriter) {
        writer.u16(reason.rawValue)
        writer.string(message)
    }
}

/// STATS (0x04), receiver → sender, optional (§6.7). Exactly 36 bytes.
public struct Stats: Equatable, Sendable {
    public static let size = 36

    public var streamId: UInt32
    public var framesReceived: UInt64
    public var framesDecoded: UInt64
    public var framesDropped: UInt64
    public var avgDecodeUs: UInt32
    public var queueDepth: UInt32

    public init(
        streamId: UInt32, framesReceived: UInt64, framesDecoded: UInt64,
        framesDropped: UInt64, avgDecodeUs: UInt32, queueDepth: UInt32
    ) {
        self.streamId = streamId
        self.framesReceived = framesReceived
        self.framesDecoded = framesDecoded
        self.framesDropped = framesDropped
        self.avgDecodeUs = avgDecodeUs
        self.queueDepth = queueDepth
    }

    init(reader: inout ByteReader) throws {
        streamId = try reader.u32()
        framesReceived = try reader.u64()
        framesDecoded = try reader.u64()
        framesDropped = try reader.u64()
        avgDecodeUs = try reader.u32()
        queueDepth = try reader.u32()
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(streamId)
        writer.u64(framesReceived)
        writer.u64(framesDecoded)
        writer.u64(framesDropped)
        writer.u32(avgDecodeUs)
        writer.u32(queueDepth)
    }
}

/// PING (0x06) and PONG (0x07) share this 12-byte layout (§6.8).
public struct Ping: Equatable, Sendable {
    public static let size = 12

    public var seq: UInt32
    /// The PING sender's monotonic clock; echoed unchanged in PONG.
    public var tUs: UInt64

    public init(seq: UInt32, tUs: UInt64) {
        self.seq = seq
        self.tUs = tUs
    }

    init(reader: inout ByteReader) throws {
        seq = try reader.u32()
        tUs = try reader.u64()
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(seq)
        writer.u64(tUs)
    }
}
