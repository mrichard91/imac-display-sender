import Foundation
import IDPProtocol

/// Everything needed to create the virtual display for a receiver, derived
/// from its HELLO. Pure, so the identity derivation is unit-tested; the
/// private-API call itself lives in CGVirtualDisplayBridge.
public struct VirtualDisplaySpec: Equatable, Sendable {
    public struct Mode: Equatable, Sendable {
        public var width: UInt32
        public var height: UInt32
        public var refreshHz: Double
    }

    /// Ours, so macOS keys saved arrangement/resolution to this app's displays.
    public static let vendorID: UInt32 = 0x1D1D
    /// Fallback density when HELLO reports no physical size.
    public static let fallbackPixelsPerInch = 110.0

    public var name: String
    public var vendorID: UInt32
    public var productID: UInt32
    public var serialNumber: UInt32
    public var maxPixelsWide: UInt32
    public var maxPixelsHigh: UInt32
    public var widthMillimeters: Double
    public var heightMillimeters: Double
    public var hiDPI: Bool
    /// First mode is the default: HiDPI "looks like" half size, so the
    /// backing store is the native panel size. Then native at 1×.
    public var modes: [Mode]

    public init(hello: Hello) {
        let refresh = hello.refreshMhz > 0 ? hello.refreshHz : 60
        name = hello.name.isEmpty ? "iMac Display" : hello.name
        vendorID = Self.vendorID
        productID = Self.productID(displayId: hello.displayId)
        serialNumber = Self.serialNumber(displayId: hello.displayId)
        maxPixelsWide = hello.panelWidthPx
        maxPixelsHigh = hello.panelHeightPx
        if hello.physicalWidthMm > 0, hello.physicalHeightMm > 0 {
            widthMillimeters = Double(hello.physicalWidthMm)
            heightMillimeters = Double(hello.physicalHeightMm)
        } else {
            widthMillimeters = Double(hello.panelWidthPx) * 25.4 / Self.fallbackPixelsPerInch
            heightMillimeters = Double(hello.panelHeightPx) * 25.4 / Self.fallbackPixelsPerInch
        }
        hiDPI = true
        modes = [
            Mode(width: hello.panelWidthPx / 2, height: hello.panelHeightPx / 2, refreshHz: refresh),
            Mode(width: hello.panelWidthPx, height: hello.panelHeightPx, refreshHz: refresh),
        ]
    }

    /// 16-bit fold of `display_id` (EDID product codes are 16 bits).
    public static func productID(displayId: UInt64) -> UInt32 {
        let folded = displayId ^ (displayId >> 16) ^ (displayId >> 32) ^ (displayId >> 48)
        return UInt32(folded & 0xFFFF)
    }

    /// 32-bit fold of `display_id`; never 0, which EDID treats as "no serial".
    public static func serialNumber(displayId: UInt64) -> UInt32 {
        let folded = UInt32(truncatingIfNeeded: displayId) ^ UInt32(truncatingIfNeeded: displayId >> 32)
        return folded == 0 ? 1 : folded
    }
}
