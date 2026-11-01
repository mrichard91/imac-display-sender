import Foundation

/// `PROTOCOL_VERSION` (§3).
public let protocolVersion: UInt16 = 1

/// Default receiver port (§1).
public let defaultPort: UInt16 = 7878

/// Message type codes (§5). Unassigned codes decode to `Message.unknown`.
public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case keyframeRequest = 0x02
    case heartbeat = 0x03
    case stats = 0x04
    case goodbye = 0x05
    case ping = 0x06
    case pong = 0x07
    case speedTestResult = 0x08
    case streamStart = 0x10
    case frame = 0x11
    case streamStop = 0x12
    case speedTestStart = 0x13
    case speedTestData = 0x14
    case speedTestEnd = 0x15
}

/// The 8-byte header in front of every message (§4).
public struct MessageHeader: Equatable, Sendable {
    public static let size = 8
    public static let maxPayloadLength: UInt32 = 64 * 1024 * 1024

    public var type: UInt8
    /// Reserved; sent as zero, tolerated (but kept for logging) when read.
    public var flags: UInt8
    public var reserved: UInt16
    public var length: UInt32

    public init(type: UInt8, length: UInt32, flags: UInt8 = 0, reserved: UInt16 = 0) {
        self.type = type
        self.length = length
        self.flags = flags
        self.reserved = reserved
    }

    public var messageType: MessageType? { MessageType(rawValue: type) }

    /// Decodes the first 8 bytes of `bytes`. Throws on a length above 64 MiB.
    public static func decode(_ bytes: Data) throws -> MessageHeader {
        var reader = ByteReader(bytes)
        let type = try reader.u8()
        let flags = try reader.u8()
        let reserved = try reader.u16()
        let length = try reader.u32()
        guard length <= maxPayloadLength else {
            throw ProtocolError.payloadTooLarge(length)
        }
        return MessageHeader(type: type, length: length, flags: flags, reserved: reserved)
    }

    /// Always encodes reserved bits as zero (§2).
    public func encode() -> Data {
        var writer = ByteWriter(capacity: Self.size)
        write(to: &writer)
        return writer.data
    }

    func write(to writer: inout ByteWriter) {
        writer.u8(type)
        writer.u8(0)
        writer.u16(0)
        writer.u32(length)
    }
}
