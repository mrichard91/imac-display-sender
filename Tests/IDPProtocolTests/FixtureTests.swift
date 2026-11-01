import Foundation
import Testing
@testable import IDPProtocol

/// `protocol/fixtures/` at the repository root, found relative to this file so
/// the tests need no bundle resources.
private let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // IDPProtocolTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("protocol/fixtures")

private func fixtureNames() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path)) ?? []
    return names.filter { $0.hasSuffix(".bin") }.sorted()
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

private func hexBytes(_ text: String) -> Data {
    let digits = text.split(whereSeparator: \.isWhitespace)
    return Data(digits.map { UInt8($0, radix: 16)! })
}

@Suite("Fixtures")
struct FixtureTests {
    @Test("every PROTOCOL §12 fixture is present")
    func allFixturesPresent() {
        let expected = [
            "frame_delta_min.bin", "frame_keyframe_min.bin", "goodbye_busy.bin", "heartbeat.bin",
            "hello_imac.bin", "keyframe_request.bin", "ping.bin", "pong.bin",
            "speed_test_data_min.bin", "speed_test_end.bin", "speed_test_result.bin",
            "speed_test_start.bin", "stats.bin", "stream_start_5k.bin", "stream_stop_1.bin",
        ]
        #expect(fixtureNames() == expected)
    }

    @Test("decode → encode is byte-identical", arguments: fixtureNames())
    func roundTrip(name: String) throws {
        let bytes = try fixture(name)
        let message = try Message.decode(bytes)
        if case .unknown = message {
            Issue.record("\(name) decoded as an unknown type")
        }
        #expect(message.encode() == bytes)
    }

    @Test("hello_imac.bin equals the hex in §6.1.2 and the struct encodes to it")
    func helloMatchesSpec() throws {
        let spec = hexBytes("""
            01 00 00 00 00 00 00 2A
            00 01
            00 00
            00 00 14 00
            00 00 0B 40
            00 00 EA 60
            02 55
            01 50
            49 4D 41 43 32 30 31 37
            00 00 00 01
            00 00 00 00
            00 04 69 4D 61 63
            """)
        let hello = Hello(
            caps: [], panelWidthPx: 5120, panelHeightPx: 2880, refreshMhz: 60_000,
            physicalWidthMm: 597, physicalHeightMm: 336,
            displayId: UInt64(bigEndian: Data("IMAC2017".utf8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }),
            codecs: .hevcMain8, maxBitrateKbps: 0, name: "iMac")

        #expect(try fixture("hello_imac.bin") == spec)
        #expect(Message.hello(hello).encode() == spec)
        #expect(try Message.decode(spec) == .hello(hello))
    }

    @Test("fixtures decode to the values listed in §12")
    func fixtureValues() throws {
        #expect(try Message.decode(fixture("stream_start_5k.bin")) == .streamStart(
            StreamStart(hiDPI: true, widthPx: 5120, heightPx: 2880, fpsMhz: 60_000, streamId: 1)))
        #expect(try Message.decode(fixture("frame_keyframe_min.bin")) == .frame(Frame(
            header: FrameHeader(ptsUs: 1_000_000, isKeyframe: true),
            accessUnit: Data([0, 0, 0, 1, 0x40, 0x01, 0x0C, 0x01]))))
        if case .frame(let frame) = try Message.decode(fixture("frame_delta_min.bin")) {
            #expect(frame.header == FrameHeader(ptsUs: 1_016_667, isKeyframe: false))
            #expect(frame.accessUnit.count == 4)
        } else {
            Issue.record("frame_delta_min.bin is not a FRAME")
        }
        #expect(try Message.decode(fixture("keyframe_request.bin")) == .keyframeRequest)
        #expect(try Message.decode(fixture("heartbeat.bin")) == .heartbeat(monoUs: 123_456_789))
        #expect(try Message.decode(fixture("goodbye_busy.bin")) == .goodbye(Goodbye(reason: .busy, message: "busy")))
        #expect(try Message.decode(fixture("stream_stop_1.bin")) == .streamStop(streamId: 1))
        #expect(try Message.decode(fixture("stats.bin")) == .stats(Stats(
            streamId: 1, framesReceived: 600, framesDecoded: 598, framesDropped: 2,
            avgDecodeUs: 3500, queueDepth: 1)))
        #expect(try Message.decode(fixture("ping.bin")) == .ping(Ping(seq: 7, tUs: 5_000_000)))
        #expect(try Message.decode(fixture("pong.bin")) == .pong(Ping(seq: 7, tUs: 5_000_000)))
        #expect(try Message.decode(fixture("speed_test_start.bin")) == .speedTestStart(
            SpeedTestStart(testId: 1, durationMs: 1000)))
        #expect(try Message.decode(fixture("speed_test_data_min.bin")) == .speedTestData(
            SpeedTestData(testId: 1, filler: Data(repeating: 0xA5, count: 16))))
        #expect(try Message.decode(fixture("speed_test_end.bin")) == .speedTestEnd(
            SpeedTestEnd(testId: 1, bytesSent: 125_000_000)))

        let result = SpeedTestResult(testId: 1, status: 0, bytesReceived: 125_000_000, elapsedUs: 1_000_000)
        #expect(try Message.decode(fixture("speed_test_result.bin")) == .speedTestResult(result))
        #expect(result.throughputKbps == 1_000_000)
    }

    @Test("the zero-copy prefixes match a fully encoded message")
    func prefixesMatchFullEncoding() throws {
        let frameBytes = try fixture("frame_keyframe_min.bin")
        guard case .frame(let frame) = try Message.decode(frameBytes) else {
            Issue.record("not a FRAME")
            return
        }
        #expect(frame.header.messagePrefix(accessUnitLength: frame.accessUnit.count) + frame.accessUnit == frameBytes)

        let dataBytes = try fixture("speed_test_data_min.bin")
        let filler = Data(repeating: 0xA5, count: 16)
        #expect(SpeedTestData.messagePrefix(testId: 1, fillerLength: filler.count) + filler == dataBytes)
    }
}
