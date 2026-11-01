import Foundation

/// SPEED_TEST_START (0x13), sender → receiver (§6.9).
public struct SpeedTestStart: Equatable, Sendable {
    public static let size = 12
    public static let durationRangeMs: ClosedRange<UInt32> = 100...10_000

    /// Non-zero; differs from the previous test on this connection.
    public var testId: UInt32
    public var durationMs: UInt32

    public init(testId: UInt32, durationMs: UInt32) {
        self.testId = testId
        self.durationMs = durationMs
    }

    init(reader: inout ByteReader) throws {
        testId = try reader.u32()
        durationMs = try reader.u32()
        try reader.skip(4)
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(testId)
        writer.u32(durationMs)
        writer.u32(0)
    }
}

/// SPEED_TEST_DATA (0x14), sender → receiver: 8 bytes + filler.
public struct SpeedTestData: Equatable, Sendable {
    public static let fixedSize = 8

    public var testId: UInt32
    public var filler: Data

    public init(testId: UInt32, filler: Data) {
        self.testId = testId
        self.filler = filler
    }

    init(reader: inout ByteReader) throws {
        testId = try reader.u32()
        try reader.skip(4)
        filler = reader.rest()
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(testId)
        writer.u32(0)
        writer.bytes(filler)
    }

    /// Message header + the fixed 8 bytes (16 bytes). Send `fillerLength`
    /// filler bytes right after it, so one shared filler buffer serves every chunk.
    public static func messagePrefix(testId: UInt32, fillerLength: Int) -> Data {
        var writer = ByteWriter(capacity: MessageHeader.size + fixedSize)
        MessageHeader(type: MessageType.speedTestData.rawValue, length: UInt32(fixedSize + fillerLength))
            .write(to: &writer)
        writer.u32(testId)
        writer.u32(0)
        return writer.data
    }
}

/// SPEED_TEST_END (0x15), sender → receiver.
public struct SpeedTestEnd: Equatable, Sendable {
    public static let size = 12

    public var testId: UInt32
    /// Total filler bytes sent (informational).
    public var bytesSent: UInt64

    public init(testId: UInt32, bytesSent: UInt64) {
        self.testId = testId
        self.bytesSent = bytesSent
    }

    init(reader: inout ByteReader) throws {
        testId = try reader.u32()
        bytesSent = try reader.u64()
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(testId)
        writer.u64(bytesSent)
    }
}

/// SPEED_TEST_RESULT (0x08), receiver → sender.
public struct SpeedTestResult: Equatable, Sendable {
    public static let size = 24
    public static let statusOK: UInt32 = 0
    public static let statusAborted: UInt32 = 1

    public var testId: UInt32
    public var status: UInt32
    public var bytesReceived: UInt64
    /// Receiver clock, START fully read → END fully read.
    public var elapsedUs: UInt64

    public init(testId: UInt32, status: UInt32, bytesReceived: UInt64, elapsedUs: UInt64) {
        self.testId = testId
        self.status = status
        self.bytesReceived = bytesReceived
        self.elapsedUs = elapsedUs
    }

    public var isOK: Bool { status == Self.statusOK }

    /// `bytes_received × 8 × 1000 / elapsed_us` (§6.9 step 5); nil when elapsed is 0.
    public var throughputKbps: UInt64? {
        guard elapsedUs > 0 else { return nil }
        let (product, overflow) = bytesReceived.multipliedReportingOverflow(by: 8_000)
        if !overflow { return product / elapsedUs }
        return UInt64(Double(bytesReceived) * 8_000 / Double(elapsedUs))
    }

    init(reader: inout ByteReader) throws {
        testId = try reader.u32()
        status = try reader.u32()
        bytesReceived = try reader.u64()
        elapsedUs = try reader.u64()
    }

    func write(to writer: inout ByteWriter) {
        writer.u32(testId)
        writer.u32(status)
        writer.u64(bytesReceived)
        writer.u64(elapsedUs)
    }
}
