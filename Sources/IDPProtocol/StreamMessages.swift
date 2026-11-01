import Foundation

/// STREAM_START (0x10), sender → receiver (§6.3).
public struct StreamStart: Equatable, Sendable {
    public static let size = 20
    public static let codecHEVCMain8: UInt8 = 1
    public static let flagHiDPI: UInt8 = 1 << 0

    public var protocolVersion: UInt16
    public var codec: UInt8
    public var flags: UInt8
    public var widthPx: UInt32
    public var heightPx: UInt32
    /// 0 = variable.
    public var fpsMhz: UInt32
    public var streamId: UInt32

    public init(
        protocolVersion: UInt16 = IDPProtocol.protocolVersion,
        codec: UInt8 = StreamStart.codecHEVCMain8,
        hiDPI: Bool,
        widthPx: UInt32,
        heightPx: UInt32,
        fpsMhz: UInt32,
        streamId: UInt32
    ) {
        self.protocolVersion = protocolVersion
        self.codec = codec
        self.flags = hiDPI ? Self.flagHiDPI : 0
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.fpsMhz = fpsMhz
        self.streamId = streamId
    }

    public var isHiDPI: Bool { flags & Self.flagHiDPI != 0 }

    init(reader: inout ByteReader) throws {
        protocolVersion = try reader.u16()
        codec = try reader.u8()
        flags = try reader.u8()
        widthPx = try reader.u32()
        heightPx = try reader.u32()
        fpsMhz = try reader.u32()
        streamId = try reader.u32()
    }

    func write(to writer: inout ByteWriter) {
        writer.u16(protocolVersion)
        writer.u8(codec)
        writer.u8(flags)
        writer.u32(widthPx)
        writer.u32(heightPx)
        writer.u32(fpsMhz)
        writer.u32(streamId)
    }
}

/// The fixed 12-byte part of a FRAME payload (§6.2). Kept separate from the
/// access unit so the encoder's output can be written without copying it.
public struct FrameHeader: Equatable, Sendable {
    public static let size = 12
    public static let flagKeyframe: UInt8 = 1 << 0

    public var ptsUs: UInt64
    public var flags: UInt8

    public init(ptsUs: UInt64, isKeyframe: Bool) {
        self.ptsUs = ptsUs
        self.flags = isKeyframe ? Self.flagKeyframe : 0
    }

    public var isKeyframe: Bool { flags & Self.flagKeyframe != 0 }

    init(reader: inout ByteReader) throws {
        ptsUs = try reader.u64()
        flags = try reader.u8()
        try reader.skip(3)
    }

    func write(to writer: inout ByteWriter) {
        writer.u64(ptsUs)
        writer.u8(flags)
        writer.zeros(3)
    }

    /// Message header + this frame header (20 bytes). Send the access unit
    /// right after it to form one FRAME message.
    public func messagePrefix(accessUnitLength: Int) -> Data {
        var writer = ByteWriter(capacity: MessageHeader.size + Self.size)
        MessageHeader(type: MessageType.frame.rawValue, length: UInt32(Self.size + accessUnitLength))
            .write(to: &writer)
        write(to: &writer)
        return writer.data
    }
}

/// FRAME (0x11): one Annex-B HEVC access unit.
public struct Frame: Equatable, Sendable {
    public var header: FrameHeader
    public var accessUnit: Data

    public init(header: FrameHeader, accessUnit: Data) {
        self.header = header
        self.accessUnit = accessUnit
    }
}
