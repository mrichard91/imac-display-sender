import CoreMedia
import Foundation
import IDPCore
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound(CGDirectDisplayID)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let id):
            return "Display \(id) did not appear in ScreenCaptureKit"
        case .permissionDenied(let detail):
            return "Screen Recording permission is required (System Settings → Privacy & Security → "
                + "Screen & System Audio Recording): \(detail)"
        }
    }
}

/// ScreenCaptureKit stream of one display, NV12 at up to 60 fps (PLAN S3).
/// Frames arrive on a private queue only when content changes.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "idp.capture", qos: .userInteractive)
    private let onFrame: (CMSampleBuffer) -> Void
    private let onStop: (Error) -> Void
    private var stream: SCStream?

    init(onFrame: @escaping (CMSampleBuffer) -> Void, onStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    func start(displayID: CGDirectDisplayID, size: PixelSize) async throws {
        let display = try await Self.findDisplay(displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.configuration(size: size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info(.capture, "capturing display \(displayID) at \(size)")
    }

    /// Changes the output size in place (after a display mode change).
    func update(size: PixelSize) async throws {
        try await stream?.updateConfiguration(Self.configuration(size: size))
        Log.info(.capture, "capture size now \(size)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            // Expected when the display is already gone.
            Log.debug(.capture, "stopCapture: \(error.localizedDescription)")
        }
        Log.info(.capture, "capture stopped")
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        onFrame(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        // The owner decides whether this is a failure (it is not during teardown).
        Log.debug(.capture, "stream stopped: \(error.localizedDescription)")
        onStop(error)
    }

    // MARK: Helpers

    private static func configuration(size: PixelSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        // NV12 video range: VideoToolbox encodes it without conversion.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = true
        configuration.capturesAudio = false
        return configuration
    }

    /// Idle/blank callbacks carry no new image; only `.complete` frames are encoded.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// A new virtual display can take a moment to show up in SCShareableContent.
    private static func findDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<20 {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                throw CaptureError.permissionDenied(error.localizedDescription)
            }
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 0 { Log.debug(.capture, "display \(displayID) appeared after \(attempt) retries") }
                return display
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CaptureError.displayNotFound(displayID)
    }
}
