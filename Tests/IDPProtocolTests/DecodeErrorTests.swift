import Foundation
import Testing
@testable import IDPProtocol

@Suite("Decode errors")
struct DecodeErrorTests {
    @Test func rejectsLengthAboveLimit() {
        let header = Data([0x11, 0, 0, 0, 0x04, 0x00, 0x00, 0x01])  // 64 MiB + 1
        #expect(throws: ProtocolError.payloadTooLarge(64 * 1024 * 1024 + 1)) {
            try MessageHeader.decode(header)
        }
    }

    @Test func acceptsLengthAtLimit() throws {
        let header = try MessageHeader.decode(Data([0x11, 0, 0, 0, 0x04, 0x00, 0x00, 0x00]))
        #expect(header.length == MessageHeader.maxPayloadLength)
    }

    @Test func rejectsWrongFixedLength() {
        // HEARTBEAT with a 4-byte payload.
        let bytes = Data([0x03, 0, 0, 0, 0, 0, 0, 4, 1, 2, 3, 4])
        #expect(throws: ProtocolError.wrongPayloadLength(type: 0x03, expected: 8, actual: 4)) {
            try Message.decode(bytes)
        }
    }

    @Test func rejectsStatsOfWrongLength() {
        var bytes = Message.stats(Stats(
            streamId: 1, framesReceived: 0, framesDecoded: 0, framesDropped: 0,
            avgDecodeUs: 0, queueDepth: 0)).encode()
        bytes.append(0)
        bytes[7] = 37
        #expect(throws: ProtocolError.self) { try Message.decode(bytes) }
    }

    @Test func rejectsStringPastPayload() {
        // GOODBYE claiming a 10-byte message but carrying 2.
        let bytes = Data([0x05, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 10, 0x68, 0x69])
        #expect(throws: ProtocolError.stringOverflow) { try Message.decode(bytes) }
    }

    @Test func unknownTypeKeepsLength() throws {
        let bytes = Data([0x42, 0, 0, 0, 0, 0, 0, 3, 9, 9, 9])
        #expect(try Message.decode(bytes) == .unknown(type: 0x42, length: 3))
    }

    @Test func helloOfAnotherVersionIsAVersionMismatch() {
        // A v2 HELLO need not have the v1 layout; this one is 4 bytes long.
        let bytes = Data([0x01, 0, 0, 0, 0, 0, 0, 4, 0x00, 0x02, 0xAB, 0xCD])
        #expect(throws: ProtocolError.versionMismatch(2)) { try Message.decode(bytes) }
    }

    @Test func toleratesReservedHeaderBits() throws {
        let bytes = Data([0x02, 0x80, 0x12, 0x34, 0, 0, 0, 0])
        #expect(try Message.decode(bytes) == .keyframeRequest)
        // Re-encoding clears them (§2).
        #expect(Message.keyframeRequest.encode() == Data([0x02, 0, 0, 0, 0, 0, 0, 0]))
    }
}
