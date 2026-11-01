import Foundation
import IDPProtocol
import Testing
@testable import IDPCore

@Suite("FramedReader")
struct FramedReaderTests {
    private let messages: [Message] = [
        .hello(Hello(caps: [.speedTest], panelWidthPx: 5120, panelHeightPx: 2880, refreshMhz: 60_000,
                     physicalWidthMm: 597, physicalHeightMm: 336, displayId: 42, codecs: .hevcMain8,
                     maxBitrateKbps: 0, name: "iMac")),
        .heartbeat(monoUs: 1),
        .keyframeRequest,
        .ping(Ping(seq: 3, tUs: 99)),
        .speedTestResult(SpeedTestResult(testId: 1, status: 0, bytesReceived: 10, elapsedUs: 20)),
    ]

    private var stream: Data { messages.reduce(Data()) { $0 + $1.encode() } }

    @Test func coalescedReadYieldsEveryMessage() throws {
        var reader = FramedReader()
        #expect(try reader.feed(stream) == messages)
        #expect(reader.bufferedByteCount == 0)
    }

    @Test func oneByteAtATime() throws {
        var reader = FramedReader()
        var decoded: [Message] = []
        for byte in stream { decoded += try reader.feed(Data([byte])) }
        #expect(decoded == messages)
    }

    @Test("arbitrary split points", arguments: [3, 7, 8, 9, 13, 50])
    func chunked(size: Int) throws {
        var reader = FramedReader()
        var decoded: [Message] = []
        let bytes = stream
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            decoded += try reader.feed(bytes.subdata(in: offset..<end))
            offset = end
        }
        #expect(decoded == messages)
    }

    @Test func skipsUnknownTypesWithoutDesync() throws {
        var unknown = Data([0x7E, 0, 0, 0, 0, 0, 0x10, 0x00])  // 4096-byte payload
        unknown.append(Data(repeating: 0xEE, count: 4096))
        let bytes = Message.heartbeat(monoUs: 5).encode() + unknown + Message.keyframeRequest.encode()

        // Split so the unknown payload spans several reads.
        var reader = FramedReader()
        var decoded: [Message] = []
        decoded += try reader.feed(bytes.prefix(30))  // HEARTBEAT + unknown header + 6 payload bytes
        #expect(reader.bufferedByteCount == 0)  // unknown payload is skipped, not buffered
        decoded += try reader.feed(bytes.subdata(in: 30..<3000))
        #expect(reader.bufferedByteCount == 0)
        decoded += try reader.feed(bytes.subdata(in: 3000..<bytes.count))
        #expect(decoded == [.heartbeat(monoUs: 5), .unknown(type: 0x7E, length: 4096), .keyframeRequest])
    }

    @Test func rejectsOversizedLength() {
        var reader = FramedReader()
        #expect(throws: ProtocolError.payloadTooLarge(0xFFFF_FFFF)) {
            try reader.feed(Data([0x11, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test func rejectsMalformedKnownType() {
        var reader = FramedReader()
        let badPing = Data([0x06, 0, 0, 0, 0, 0, 0, 2, 0, 0])
        #expect(throws: ProtocolError.self) { try reader.feed(badPing) }
    }
}
