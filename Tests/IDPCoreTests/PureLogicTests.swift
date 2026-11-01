import Foundation
import IDPProtocol
import Network
import Testing
@testable import IDPCore

@Suite("Annex-B conversion")
struct AnnexBTests {
    @Test func replacesFourByteLengthsAndPrependsParameterSets() throws {
        let slice1 = Data([0x26, 0x01, 0xAA, 0xBB])
        let slice2 = Data([0x02, 0x01, 0xCC])
        var hvcc = Data([0, 0, 0, 4]) + slice1
        hvcc += Data([0, 0, 0, 3]) + slice2
        let vps = Data([0x40, 0x01, 0x0C])
        let sps = Data([0x42, 0x01, 0x01])
        let pps = Data([0x44, 0x01, 0xC1])

        let out = try AnnexB.fromLengthPrefixed(hvcc, nalLengthSize: 4, parameterSets: [vps, sps, pps])
        var expected = Data()
        for nal in [vps, sps, pps, slice1, slice2] { expected += AnnexB.startCode + nal }
        #expect(out == expected)
        #expect(AnnexB.nalUnits(in: out) == [vps, sps, pps, slice1, slice2])
        #expect(AnnexB.nalUnits(in: out).compactMap(AnnexB.hevcNALType) == [32, 33, 34, 19, 1])
    }

    @Test func deltaFrameHasNoParameterSets() throws {
        let nal = Data([0x02, 0x01, 0x10, 0x20])
        let out = try AnnexB.fromLengthPrefixed(Data([0, 0, 0, 4]) + nal, nalLengthSize: 4)
        #expect(out == AnnexB.startCode + nal)
    }

    @Test func handlesShortLengthPrefixes() throws {
        let nal = Data([0x02, 0x01, 0x77])
        #expect(try AnnexB.fromLengthPrefixed(Data([0, 3]) + nal, nalLengthSize: 2) == AnnexB.startCode + nal)
        #expect(try AnnexB.fromLengthPrefixed(Data([3]) + nal, nalLengthSize: 1) == AnnexB.startCode + nal)
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: AnnexB.ConversionError.truncatedNAL(offset: 0)) {
            try AnnexB.fromLengthPrefixed(Data([0, 0, 0, 9, 1, 2]), nalLengthSize: 4)
        }
        #expect(throws: AnnexB.ConversionError.invalidLengthSize(3)) {
            try AnnexB.fromLengthPrefixed(Data(), nalLengthSize: 3)
        }
    }

    @Test func splitterAcceptsThreeByteStartCodes() {
        let stream = Data([0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x26, 0x01])
        #expect(AnnexB.nalUnits(in: stream) == [Data([0x40, 0x01]), Data([0x26, 0x01])])
    }
}

@Suite("Bitrate policy")
struct BitratePolicyTests {
    @Test func autoIsSixtyPercentClamped() {
        #expect(BitratePolicy.autoKbps(measuredKbps: 100_000, receiverMaxKbps: 0) == 60_000)
        #expect(BitratePolicy.autoKbps(measuredKbps: 5_000, receiverMaxKbps: 0) == 10_000)
        #expect(BitratePolicy.autoKbps(measuredKbps: 10_000_000, receiverMaxKbps: 0) == 200_000)
        #expect(BitratePolicy.autoKbps(measuredKbps: 1_000_000, receiverMaxKbps: 50_000) == 50_000)
    }

    @Test func targetForModes() {
        #expect(BitratePolicy.targetKbps(mode: .fixed(mbps: 40), measuredKbps: 1_000, receiverMaxKbps: 0) == 40_000)
        #expect(BitratePolicy.targetKbps(mode: .auto, measuredKbps: nil, receiverMaxKbps: 0) == 80_000)
        #expect(BitratePolicy.targetKbps(mode: .auto, measuredKbps: nil, receiverMaxKbps: 30_000) == 30_000)
        #expect(BitratePolicy.targetKbps(mode: .auto, measuredKbps: 900_000, receiverMaxKbps: 0) == 200_000)
    }
}

@Suite("Small helpers")
struct HelperTests {
    @Test func backoffDoublesToTenSeconds() {
        var backoff = ReconnectBackoff()
        #expect((0..<7).map { _ in backoff.nextDelay() } == [1, 2, 4, 8, 10, 10, 10])
        backoff.reset()
        #expect(backoff.nextDelay() == 1)
    }

    @Test func rttIsMinimumOfLastFive() {
        var tracker = RTTTracker(window: 5)
        #expect(tracker.minimumMicroseconds == nil)
        for sample: UInt64 in [900, 300, 500, 700, 800, 600] { tracker.add(microseconds: sample) }
        #expect(tracker.minimumMicroseconds == 300)
        tracker.add(microseconds: 650)  // pushes 300 out
        #expect(tracker.minimumMicroseconds == 500)
    }

    @Test func linkClassification() {
        #expect(LinkKind.classify(interfaceName: "bridge0", type: .other) == .thunderboltBridge)
        #expect(LinkKind.classify(interfaceName: "bridge100", type: .wiredEthernet) == .thunderboltBridge)
        #expect(LinkKind.classify(interfaceName: "en0", type: .wifi) == .wifi)
        #expect(LinkKind.classify(interfaceName: "en7", type: .wiredEthernet) == .ethernet)
        #expect(LinkKind.classify(interfaceName: "lo0", type: .loopback) == .loopback)
        #expect(LinkKind.classify(interfaceName: "utun3", type: .other) == .other)
        #expect(LinkKind.classify(interfaceName: nil, type: nil) == .other)
    }

    @Test func virtualDisplaySpecFromHello() {
        let hello = Hello(
            caps: [], panelWidthPx: 5120, panelHeightPx: 2880, refreshMhz: 60_000,
            physicalWidthMm: 597, physicalHeightMm: 336, displayId: 0x494D_4143_3230_3137,
            codecs: .hevcMain8, maxBitrateKbps: 0, name: "iMac")
        let spec = VirtualDisplaySpec(hello: hello)
        #expect(spec.vendorID == 0x1D1D)
        #expect(spec.productID <= 0xFFFF)
        #expect(spec.productID == VirtualDisplaySpec(hello: hello).productID)
        #expect(spec.serialNumber == 0x494D_4143 ^ 0x3230_3137)
        #expect(spec.widthMillimeters == 597)
        #expect(spec.modes.first == .init(width: 2560, height: 1440, refreshHz: 60))
        #expect(spec.modes.last == .init(width: 5120, height: 2880, refreshHz: 60))

        var unknownSize = hello
        unknownSize.physicalWidthMm = 0
        let fallback = VirtualDisplaySpec(hello: unknownSize)
        #expect(abs(fallback.widthMillimeters - 5120 * 25.4 / 110) < 0.001)
        #expect(VirtualDisplaySpec.serialNumber(displayId: 0) == 1)
    }
}

@Suite("Receiver address and launch options")
struct AddressTests {
    @Test func parsesHostsAndPorts() {
        #expect(ReceiverAddress.parse("10.99.0.2") == ReceiverAddress(host: "10.99.0.2", port: 7878))
        #expect(ReceiverAddress.parse(" imac.local:9000 ") == ReceiverAddress(host: "imac.local", port: 9000))
        #expect(ReceiverAddress.parse("fe80::1") == ReceiverAddress(host: "fe80::1", port: 7878))
        #expect(ReceiverAddress.parse("[fe80::1%bridge0]:8000") == ReceiverAddress(host: "fe80::1%bridge0", port: 8000))
        #expect(ReceiverAddress.parse("host", defaultPort: 1234)?.port == 1234)
        #expect(ReceiverAddress.parse("") == nil)
        #expect(ReceiverAddress.parse("host:0") == nil)
        #expect(ReceiverAddress.parse("host:99999") == nil)
        #expect(ReceiverAddress.parse("[::1]x") == nil)
        #expect(ReceiverAddress(host: "::1", port: 1).description == "[::1]:1")
    }

    @Test func parsesLaunchArguments() {
        #expect(LaunchOptions.parse(["app"]).address == nil)
        #expect(LaunchOptions.parse(["app", "--host", "10.99.0.2"]).address == ReceiverAddress(host: "10.99.0.2"))
        #expect(LaunchOptions.parse(["app", "-NSDocumentRevisionsDebugMode", "YES", "--host", "imac", "--port", "9000"])
            .address == ReceiverAddress(host: "imac", port: 9000))
        #expect(LaunchOptions.parse(["app", "--port", "9000"]).address == nil)
        #expect(LaunchOptions.parse(["app", "--host"]).address == nil)
    }
}
