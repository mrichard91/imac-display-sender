import Foundation

/// HELLO (0x01), receiver → sender (§6.1).
public struct Hello: Equatable, Sendable {
    public struct Caps: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let canScale = Caps(rawValue: 1 << 0)
        public static let stats = Caps(rawValue: 1 << 1)
        public static let speedTest = Caps(rawValue: 1 << 2)
    }

    public struct Codecs: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let hevcMain8 = Codecs(rawValue: 1 << 0)
    }

    static let fixedSize = 36

    public var protocolVersion: UInt16
    public var caps: Caps
    public var panelWidthPx: UInt32
    public var panelHeightPx: UInt32
    public var refreshMhz: UInt32
    public var physicalWidthMm: UInt16
    public var physicalHeightMm: UInt16
    /// Opaque, stable receiver identity (§6.1.1).
    public var displayId: UInt64
    public var codecs: Codecs
    /// 0 = no preference.
    public var maxBitrateKbps: UInt32
    public var name: String

    public init(
        protocolVersion: UInt16 = IDPProtocol.protocolVersion,
        caps: Caps,
        panelWidthPx: UInt32,
        panelHeightPx: UInt32,
        refreshMhz: UInt32,
        physicalWidthMm: UInt16,
        physicalHeightMm: UInt16,
        displayId: UInt64,
        codecs: Codecs,
        maxBitrateKbps: UInt32,
        name: String
    ) {
        self.protocolVersion = protocolVersion
        self.caps = caps
        self.panelWidthPx = panelWidthPx
        self.panelHeightPx = panelHeightPx
        self.refreshMhz = refreshMhz
        self.physicalWidthMm = physicalWidthMm
        self.physicalHeightMm = physicalHeightMm
        self.displayId = displayId
        self.codecs = codecs
        self.maxBitrateKbps = maxBitrateKbps
        self.name = name
    }

    public var refreshHz: Double { Double(refreshMhz) / 1000 }

    init(reader: inout ByteReader) throws {
        protocolVersion = try reader.u16()
        caps = Caps(rawValue: try reader.u16())
        panelWidthPx = try reader.u32()
        panelHeightPx = try reader.u32()
        refreshMhz = try reader.u32()
        physicalWidthMm = try reader.u16()
        physicalHeightMm = try reader.u16()
        displayId = try reader.u64()
        codecs = Codecs(rawValue: try reader.u32())
        maxBitrateKbps = try reader.u32()
        name = try reader.string()
    }

    func write(to writer: inout ByteWriter) {
        writer.u16(protocolVersion)
        writer.u16(caps.rawValue)
        writer.u32(panelWidthPx)
        writer.u32(panelHeightPx)
        writer.u32(refreshMhz)
        writer.u16(physicalWidthMm)
        writer.u16(physicalHeightMm)
        writer.u64(displayId)
        writer.u32(codecs.rawValue)
        writer.u32(maxBitrateKbps)
        writer.string(name)
    }
}
