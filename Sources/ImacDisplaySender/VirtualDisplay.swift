import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import IDPCore
import IDPProtocol

struct PixelSize: Equatable, CustomStringConvertible {
    var width: Int
    var height: Int

    var description: String { "\(width)x\(height)" }
}

enum VirtualDisplayError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Virtual displays are unavailable: \(reason)"
        }
    }
}

/// The virtual display that mirrors one receiver's panel (PLAN S2). Created
/// only after a valid HELLO; released on disconnect. The app never changes its
/// mode itself: doing so can make the display un-removable until logout.
@MainActor
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let spec: VirtualDisplaySpec
    private(set) var currentPixelSize: PixelSize

    /// The user picked another mode in System Settings.
    var onModeChange: ((PixelSize) -> Void)?
    /// The system tore the display down.
    var onTerminated: (() -> Void)?

    private var bridge: IDPVirtualDisplay?
    private let callbackBox = CallbackBox()

    init(hello: Hello) throws {
        if let reason = IDPVirtualDisplay.unavailabilityReason() {
            throw VirtualDisplayError.unavailable(reason)
        }
        let spec = VirtualDisplaySpec(hello: hello)
        let configuration = IDPVirtualDisplayConfiguration()
        configuration.name = spec.name
        configuration.vendorID = spec.vendorID
        configuration.productID = spec.productID
        configuration.serialNumber = spec.serialNumber
        configuration.maxPixelsWide = spec.maxPixelsWide
        configuration.maxPixelsHigh = spec.maxPixelsHigh
        configuration.sizeInMillimeters = CGSize(width: spec.widthMillimeters, height: spec.heightMillimeters)
        configuration.hiDPI = spec.hiDPI
        configuration.modes = spec.modes.map {
            IDPVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.refreshHz)
        }

        let box = callbackBox
        let bridge = try IDPVirtualDisplay(configuration: configuration, queue: .main) {
            MainActor.assumeIsolated { box.owner?.onTerminated?() }
        }
        self.bridge = bridge
        self.spec = spec
        displayID = bridge.displayID
        currentPixelSize = Self.pixelSize(of: bridge.displayID)
            ?? PixelSize(width: Int(spec.maxPixelsWide), height: Int(spec.maxPixelsHigh))
        callbackBox.owner = self

        CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(box).toOpaque())
        Log.info(.display, "created display \(displayID) \"\(spec.name)\" max \(spec.maxPixelsWide)x\(spec.maxPixelsHigh), "
            + "vendor 0x\(String(spec.vendorID, radix: 16)) product 0x\(String(spec.productID, radix: 16)) "
            + "serial 0x\(String(spec.serialNumber, radix: 16)), now \(currentPixelSize)")
    }

    /// Removes the display; macOS moves windows back within ~2 s. Idempotent.
    func release() {
        guard let bridge else { return }
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(callbackBox).toOpaque())
        callbackBox.owner = nil
        bridge.invalidate()
        self.bridge = nil
        Log.info(.display, "released display \(displayID)")
    }

    var isActive: Bool { bridge != nil }

    /// Current backing-store size, if the display has a mode yet.
    static func pixelSize(of displayID: CGDirectDisplayID) -> PixelSize? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0, mode.pixelHeight > 0 else {
            return nil
        }
        return PixelSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    fileprivate func displayReconfigured() {
        guard bridge != nil, let size = Self.pixelSize(of: displayID), size != currentPixelSize else { return }
        Log.info(.display, "display \(displayID) mode changed \(currentPixelSize) -> \(size)")
        currentPixelSize = size
        onModeChange?(size)
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let owner = box.owner, owner.displayID == display else { return }
                owner.displayReconfigured()
            }
        }
    }
}

/// Lets C callbacks reach the display without retaining it.
private final class CallbackBox: @unchecked Sendable {
    weak var owner: VirtualDisplay?
}
