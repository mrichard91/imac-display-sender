import CoreMedia
import Foundation
import IDPCore
import IDPProtocol

/// The per-frame hot path: capture → encoder → connection. Owned by
/// `SenderSession`; the session decides when streams start and stop and
/// sends STREAM_START/STREAM_STOP, this class moves frames.
///
/// Capture callbacks run on the capture queue, encoder output on a
/// VideoToolbox thread; shared state is behind a lock.
final class StreamPipeline: @unchecked Sendable {
    /// More encoded frames than this waiting for the socket → skip captures (§8).
    static let maxPendingFrames = 2

    private let connection: Connection
    private var capture: Capture?
    private let state = Locked(State())
    /// Held across the decide-and-submit step so `pauseAndDrain` cannot slip
    /// between a frame being accepted and it reaching the encoder.
    private let submitLock = NSLock()

    private struct State {
        var encoder: Encoder?
        var active = false
        /// Teardown has begun: capture errors from here on are expected.
        var stopping = false
        var forceKeyframe = true
        /// A forced keyframe is in the encoder. Nothing else is submitted until
        /// it is out, so no delta frame can overtake it (§6.3, §6.4).
        var keyframeInFlight = false
        /// Presentation times handed to VideoToolbox must strictly increase.
        var lastSubmittedPts: CMTime?
        var framesSkipped = 0
        /// Newest captured image, re-encoded when a keyframe is needed while
        /// the screen is idle (ScreenCaptureKit only delivers on change).
        var latestImage: CVImageBuffer?
    }

    private let repeatQueue = DispatchQueue(label: "idp.pipeline.repeat", qos: .userInteractive)

    /// Called on the capture queue when ScreenCaptureKit stops on its own.
    var onCaptureStopped: ((Error) -> Void)?

    init(connection: Connection) {
        self.connection = connection
    }

    var framesSkipped: Int { state.value.framesSkipped }

    /// Creates the encoder for `size`. Frames flow once `resume()` is called;
    /// the caller sends STREAM_START in between.
    func prepare(size: PixelSize, bitrateKbps: UInt32) throws {
        let connection = self.connection
        let encoder = try Encoder(
            size: size, bitrateKbps: bitrateKbps,
            onOutput: { header, accessUnit in connection.sendFrame(header: header, accessUnit: accessUnit) },
            onForcedKeyframe: { [weak self] encoder, delivered in
                self?.forcedKeyframeDone(by: encoder, delivered: delivered)
            })
        let old = state.withLock { state -> Encoder? in
            defer {
                state.encoder = encoder
                state.keyframeInFlight = false
                state.latestImage = nil  // wrong size for the new encoder
            }
            return state.encoder
        }
        old?.invalidate()
    }

    func startCapture(displayID: CGDirectDisplayID, size: PixelSize) async throws {
        let capture = Capture(
            onFrame: { [weak self] sample in self?.handle(sample) },
            onStop: { [weak self] error in
                guard let self, !self.state.value.stopping else { return }
                self.onCaptureStopped?(error)
            })
        self.capture = capture
        try await capture.start(displayID: displayID, size: size)
    }

    func updateCapture(size: PixelSize) async throws {
        try await capture?.update(size: size)
    }

    /// Start passing frames to the encoder; the first one is a keyframe.
    func resume() {
        state.withLock {
            $0.active = true
            $0.forceKeyframe = true
        }
        encodeLatestImage()
    }

    /// Stop passing frames and wait until every frame already submitted to the
    /// encoder has been handed to the connection, so nothing from this stream
    /// can follow a STREAM_STOP sent afterwards.
    func pauseAndDrain() {
        submitLock.lock()
        let encoder = state.withLock { state -> Encoder? in
            state.active = false
            return state.encoder
        }
        submitLock.unlock()
        encoder?.flush()
    }

    /// The next frame sent is a keyframe; if the screen is idle, the latest
    /// image is re-encoded now so the receiver is not left waiting.
    func requestKeyframe() {
        state.withLock { $0.forceKeyframe = true }
        encodeLatestImage()
    }

    func setBitrate(kbps: UInt32) {
        state.value.encoder?.setBitrate(kbps: kbps)
    }

    /// Call before releasing the virtual display, so the capture error that
    /// release causes is not reported as a failure.
    func prepareToStop() {
        state.withLock { $0.stopping = true }
    }

    /// Tears everything down. Safe to call more than once.
    func stop() async {
        prepareToStop()
        let encoder = state.withLock { state -> Encoder? in
            state.active = false
            state.latestImage = nil
            defer { state.encoder = nil }
            return state.encoder
        }
        encoder?.invalidate()
        await capture?.stop()
        capture = nil
    }

    /// Encoder thread. A forced keyframe that did not come out (dropped,
    /// failed, or delivered as a delta frame) is re-armed so the next frame
    /// is forced again.
    private func forcedKeyframeDone(by encoder: Encoder, delivered: Bool) {
        state.withLock { state in
            guard state.encoder === encoder else { return }
            state.keyframeInFlight = false
            if !delivered { state.forceKeyframe = true }
        }
    }

    // MARK: Hot path

    /// Capture queue.
    private func handle(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        state.withLock { $0.latestImage = image }
        submit(image, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample), isRepeat: false)
    }

    /// Delivers a pending keyframe from the latest image, retrying while the
    /// link is backed up or a speed test runs (up to ~10 s).
    private func encodeLatestImage(attempt: Int = 0) {
        repeatQueue.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, let image = self.state.value.latestImage else { return }
            // Stamped "now"; `submit` moves it past the last submitted frame if needed.
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if self.submit(image, presentationTime: now, isRepeat: true) == .deferred, attempt < 200 {
                self.encodeLatestImage(attempt: attempt + 1)
            }
        }
    }

    private enum SubmitResult { case submitted, skipped, deferred }

    @discardableResult
    private func submit(_ image: CVImageBuffer, presentationTime: CMTime, isRepeat: Bool) -> SubmitResult {
        submitLock.lock()
        defer { submitLock.unlock() }
        var result = SubmitResult.skipped
        let decision = state.withLock { state -> (Encoder, Bool, CMTime)? in
            guard state.active, let encoder = state.encoder else { return nil }
            // A repeat only exists to deliver a pending keyframe.
            if isRepeat && !state.forceKeyframe { return nil }
            // Skip before the encoder, never after it (§8); also during speed tests (§6.9).
            let backlog = connection.pendingFrames + encoder.inFlight
            if connection.isSpeedTestRunning || backlog > Self.maxPendingFrames || state.keyframeInFlight {
                if isRepeat { result = .deferred } else { state.framesSkipped += 1 }
                return nil
            }
            // A capture can be delivered after a repeat stamped later than it
            // was captured: skip it rather than go back in time. A repeat is
            // moved just past the last frame instead.
            var pts = presentationTime
            if let last = state.lastSubmittedPts, CMTimeCompare(pts, last) <= 0 {
                guard isRepeat else {
                    state.framesSkipped += 1
                    return nil
                }
                pts = CMTimeAdd(last, CMTime(value: 1, timescale: 1_000_000))
            }
            state.lastSubmittedPts = pts
            let force = state.forceKeyframe
            state.forceKeyframe = false
            state.keyframeInFlight = force
            return (encoder, force, pts)
        }
        guard let (encoder, forceKeyframe, pts) = decision else { return result }
        encoder.encode(image, presentationTime: pts, forceKeyframe: forceKeyframe)
        return .submitted
    }
}
