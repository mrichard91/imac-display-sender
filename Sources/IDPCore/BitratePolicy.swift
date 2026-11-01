import Foundation

/// How the encoder's target bitrate is chosen.
public enum BitrateMode: Equatable, Hashable, Sendable {
    /// From a speed test at connect time (or the last one run).
    case auto
    case fixed(mbps: Int)

    public static let presetsMbps = [20, 40, 80, 150]
}

public enum BitratePolicy {
    public static let defaultKbps: UInt32 = 80_000
    public static let autoRangeKbps: ClosedRange<UInt32> = 10_000...200_000
    /// Leave headroom for keyframe bursts and link jitter.
    public static let autoFraction = 0.6

    /// 60 % of the measured throughput, clamped to 10–200 Mbit/s and to the
    /// receiver's `max_bitrate_kbps` hint when it is set.
    public static func autoKbps(measuredKbps: UInt64, receiverMaxKbps: UInt32) -> UInt32 {
        let scaled = Double(measuredKbps) * autoFraction
        var kbps = UInt32(min(Double(autoRangeKbps.upperBound), max(Double(autoRangeKbps.lowerBound), scaled)))
        if receiverMaxKbps > 0 { kbps = min(kbps, receiverMaxKbps) }
        return kbps
    }

    /// The encoder target for `mode`. Auto without a measurement falls back to
    /// the default, still respecting the receiver's hint.
    public static func targetKbps(mode: BitrateMode, measuredKbps: UInt64?, receiverMaxKbps: UInt32) -> UInt32 {
        switch mode {
        case .fixed(let mbps):
            return UInt32(clamping: max(1, mbps) * 1_000)
        case .auto:
            if let measuredKbps {
                return autoKbps(measuredKbps: measuredKbps, receiverMaxKbps: receiverMaxKbps)
            }
            return receiverMaxKbps > 0 ? min(defaultKbps, receiverMaxKbps) : defaultKbps
        }
    }
}
