import Combine
import CoreGraphics
import Foundation
import IDPCore
import IDPProtocol

/// The sender state machine (PROTOCOL §7.2) and everything the menu shows.
///
/// IDLE → connecting → waiting for HELLO → [link test] → starting stream →
/// streaming; any disconnect releases the display and, unless the user asked
/// for it, reconnects with 1, 2, 4 … 10 s backoff.
@MainActor
final class SenderSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(attempt: Int)
        case awaitingHello
        case testingLink
        case startingStream
        case streaming
        case reconnecting(inSeconds: Int)
    }

    static let connectSpeedTestMs: UInt32 = 500
    static let userSpeedTestMs: UInt32 = 1_000

    @Published private(set) var phase = Phase.idle
    @Published private(set) var target: ReceiverAddress?
    @Published private(set) var hello: Hello?
    @Published private(set) var link: LinkInfo?
    @Published private(set) var rttMicroseconds: UInt64?
    @Published private(set) var effectiveBitsPerSecond: Double = 0
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var framesSkipped = 0
    @Published private(set) var targetKbps = BitratePolicy.defaultKbps
    @Published private(set) var streamSize: PixelSize?
    @Published private(set) var lastSpeedTest: SpeedTestReport?
    @Published private(set) var speedTestRunning = false
    /// Kept apart from `lastError`: a failed test does not stop the stream.
    @Published private(set) var lastSpeedTestError: String?
    @Published private(set) var lastError: String?

    let preferences: Preferences

    private var connection: Connection?
    private var display: VirtualDisplay?
    private var pipeline: StreamPipeline?
    private var streamId: UInt32 = 0
    private var attempt = 0
    private var backoff = ReconnectBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var statsTimer: Timer?
    /// From a speed test on the current connection; drives Auto bitrate.
    private var measuredKbps: UInt64?
    private var subscriptions = Set<AnyCancellable>()

    init(preferences: Preferences) {
        self.preferences = preferences
        preferences.$bitrateMode
            .dropFirst()
            .sink { [weak self] mode in
                MainActor.assumeIsolated { self?.applyBitrate(mode: mode) }
            }
            .store(in: &subscriptions)
    }

    // MARK: Derived state for the UI

    var isConnected: Bool {
        switch phase {
        case .awaitingHello, .testingLink, .startingStream, .streaming: return true
        default: return false
        }
    }

    var isActive: Bool { phase != .idle }

    var canRunSpeedTest: Bool {
        guard let hello, hello.caps.contains(.speedTest), !speedTestRunning else { return false }
        return phase == .streaming || phase == .startingStream
    }

    var statusText: String {
        let address = target?.description ?? ""
        let name = hello.map { "\"\($0.name)\"" } ?? address
        switch phase {
        case .idle: return "Disconnected"
        case .connecting(let attempt):
            return attempt > 1 ? "Connecting to \(address) (attempt \(attempt))" : "Connecting to \(address)"
        case .awaitingHello: return "Connected to \(address), waiting for receiver"
        case .testingLink: return "Testing link to \(name)…"
        case .startingStream: return "Starting stream to \(name)…"
        case .streaming:
            if speedTestRunning { return "Paused for speed test" }
            // The mode is on the Stream row; the headline stays one line.
            return hello == nil ? "Streaming" : "Streaming to \(name)"
        case .reconnecting(let seconds): return "Reconnecting to \(address) in \(seconds) s"
        }
    }

    var menuBarSymbol: String {
        switch phase {
        case .idle: return lastError == nil ? "display" : "exclamationmark.triangle"
        case .streaming: return "display.2"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    // MARK: User actions

    func connect(to address: ReceiverAddress) {
        Log.info(.session, "user connect to \(address)")
        if connection != nil || reconnectTask != nil { disconnect() }
        target = address
        attempt = 0
        backoff.reset()
        lastError = nil
        lastSpeedTest = nil
        lastSpeedTestError = nil
        open()
    }

    /// User intent: GOODBYE NORMAL, release the display, no reconnect.
    func disconnect() {
        Log.info(.session, "user disconnect")
        cancelReconnect()
        if let connection {
            self.connection = nil
            connection.close(goodbye: .normal)
        }
        tearDown()
        target = nil
        phase = .idle
        lastError = nil
    }

    func runSpeedTest() {
        guard canRunSpeedTest, let connection else { return }
        speedTestRunning = true
        connection.runSpeedTest(durationMs: Self.userSpeedTestMs) { [weak self] result in
            Self.onMain { self?.speedTestFinished(result, on: connection) }
        }
    }

    /// Quit / SIGTERM: say goodbye and give the socket a moment to flush it.
    func shutdown(completion: @escaping @MainActor () -> Void) {
        let wasConnected = connection != nil
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasConnected ? 0.3 : 0)) {
            MainActor.assumeIsolated { completion() }
        }
    }

    // MARK: Connection lifecycle

    private func open() {
        guard let target else { return }
        attempt += 1
        phase = .connecting(attempt: attempt)
        streamId = 0
        measuredKbps = nil
        let connection = Connection(host: target.host, port: target.port)
        connection.onEvent = { [weak self] event in
            Self.onMain { self?.handle(event, from: connection) }
        }
        self.connection = connection
        connection.start()
    }

    private func handle(_ event: ConnectionEvent, from source: Connection) {
        guard source === connection else { return }  // stale connection
        switch event {
        case .connected(let link):
            self.link = link
            phase = .awaitingHello
        case .linkChanged(let link):
            self.link = link
        case .hello(let hello):
            receivedHello(hello, on: source)
        case .rttUpdated(let microseconds):
            rttMicroseconds = microseconds
        case .message(.keyframeRequest):
            Log.debug(.session, "KEYFRAME_REQUEST")
            pipeline?.requestKeyframe()
        case .message(.stats(let stats)):
            Log.debug(.session, "STATS stream \(stats.streamId): received \(stats.framesReceived), "
                + "decoded \(stats.framesDecoded), dropped \(stats.framesDropped), "
                + "decode \(stats.avgDecodeUs) us, queue \(stats.queueDepth)")
        case .message:
            break
        case .closed(let reason):
            connectionClosed(reason)
        }
    }

    private func receivedHello(_ hello: Hello, on connection: Connection) {
        self.hello = hello
        backoff.reset()
        attempt = 0
        // The receiver answered: whatever made earlier attempts fail is over.
        lastError = nil
        if let target { preferences.remember(target, name: hello.name) }

        if preferences.bitrateMode == .auto, hello.caps.contains(.speedTest) {
            phase = .testingLink
            speedTestRunning = true
            connection.runSpeedTest(durationMs: Self.connectSpeedTestMs) { [weak self] result in
                Self.onMain {
                    guard let self else { return }
                    self.speedTestFinished(result, on: connection)
                    if connection === self.connection { self.startStream(hello: hello, on: connection) }
                }
            }
        } else {
            startStream(hello: hello, on: connection)
        }
    }

    /// HELLO → virtual display → encoder → capture → STREAM_START → keyframe.
    private func startStream(hello: Hello, on connection: Connection) {
        phase = .startingStream
        let display: VirtualDisplay
        let pipeline = StreamPipeline(connection: connection)
        let size: PixelSize
        do {
            display = try VirtualDisplay(hello: hello)
            self.display = display
            size = Self.clamp(display.currentPixelSize, to: hello)
            applyBitrate(mode: preferences.bitrateMode)
            try pipeline.prepare(size: size, bitrateKbps: targetKbps)
        } catch {
            fail(error.localizedDescription, retry: false)
            return
        }
        self.pipeline = pipeline
        display.onModeChange = { [weak self] newSize in self?.displayModeChanged(to: newSize) }
        display.onTerminated = { [weak self] in self?.fail("The virtual display was removed by macOS", retry: true) }
        pipeline.onCaptureStopped = { [weak self, weak pipeline] error in
            Self.onMain {
                guard let self, let pipeline, pipeline === self.pipeline else { return }
                self.fail("Screen capture stopped: \(error.localizedDescription)", retry: true)
            }
        }

        Task {
            do {
                try await pipeline.startCapture(displayID: display.displayID, size: size)
            } catch {
                guard pipeline === self.pipeline else { return }
                // Retrying cannot fix a missing Screen Recording grant.
                fail(error.localizedDescription, retry: !Self.isPermissionError(error))
                return
            }
            guard pipeline === self.pipeline else { return }
            beginStream(size: size)
        }
    }

    private func beginStream(size: PixelSize) {
        guard let connection, let pipeline, let display else { return }
        streamId += 1
        let start = StreamStart(
            hiDPI: Self.isHiDPI(display.displayID), widthPx: UInt32(size.width), heightPx: UInt32(size.height),
            fpsMhz: 60_000, streamId: streamId)
        connection.send(.streamStart(start))
        pipeline.resume()  // forces a keyframe first (§6.3)
        streamSize = size
        phase = .streaming
        startStatsTimer()
        Log.info(.session, "stream \(streamId) started at \(size), \(targetKbps / 1000) Mbit/s target")

        // A mode change that landed while this stream was starting (e.g. macOS
        // restoring the remembered mode) was not acted on; do it now (§7.2).
        if let hello, Self.clamp(display.currentPixelSize, to: hello) != size {
            displayModeChanged(to: display.currentPixelSize)
        }
    }

    /// STREAM_STOP, reconfigure encoder and capture, STREAM_START, keyframe (§6.3).
    private func displayModeChanged(to newSize: PixelSize) {
        guard phase == .streaming else {
            // `beginStream` compares the display's current mode with what it
            // started and comes back here if they differ.
            if phase == .startingStream { Log.info(.session, "mode change to \(newSize) deferred until the stream is up") }
            return
        }
        guard let connection, let pipeline, let hello else { return }
        let size = Self.clamp(newSize, to: hello)
        phase = .startingStream
        pipeline.pauseAndDrain()
        connection.send(.streamStop(streamId: streamId))
        Log.info(.session, "stream \(streamId) stopped for mode change")
        Task {
            do {
                try pipeline.prepare(size: size, bitrateKbps: targetKbps)
                try await pipeline.updateCapture(size: size)
            } catch {
                guard pipeline === self.pipeline else { return }
                fail("Could not switch to \(size): \(error.localizedDescription)", retry: true)
                return
            }
            guard pipeline === self.pipeline else { return }
            beginStream(size: size)
        }
    }

    private func connectionClosed(_ reason: DisconnectReason) {
        connection = nil
        tearDown()
        lastError = reason.description
        if reason.isRetryable, preferences.autoReconnect, target != nil {
            scheduleReconnect()
        } else {
            phase = .idle
        }
    }

    /// Local failure while connected: GOODBYE INTERNAL_ERROR, then maybe retry.
    private func fail(_ message: String, retry: Bool) {
        Log.error(.session, message)
        if let connection {
            self.connection = nil
            connection.close(goodbye: .internalError, message: message)
        }
        tearDown()
        lastError = message
        if retry, preferences.autoReconnect, target != nil {
            scheduleReconnect()
        } else {
            phase = .idle
        }
    }

    /// Releases the display first (windows come back within 2 s, §7.2), then
    /// stops capture and the encoder in the background.
    private func tearDown() {
        pipeline?.prepareToStop()
        display?.release()
        display = nil
        if let pipeline {
            self.pipeline = nil
            Task { await pipeline.stop() }
        }
        statsTimer?.invalidate()
        statsTimer = nil
        hello = nil
        link = nil
        rttMicroseconds = nil
        streamSize = nil
        speedTestRunning = false
        effectiveBitsPerSecond = 0
        framesPerSecond = 0
        framesSkipped = 0
    }

    private func scheduleReconnect() {
        cancelReconnect()
        let delay = Int(backoff.nextDelay())
        Log.info(.session, "reconnecting in \(delay) s")
        reconnectTask = Task { [weak self] in
            for remaining in stride(from: delay, to: 0, by: -1) {
                self?.phase = .reconnecting(inSeconds: remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.reconnectTask = nil
            self.open()
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: Speed test and bitrate

    private func speedTestFinished(_ result: Result<SpeedTestReport, SpeedTestError>, on source: Connection) {
        guard source === connection else { return }
        speedTestRunning = false
        switch result {
        case .success(let report):
            lastSpeedTest = report
            lastSpeedTestError = nil
            measuredKbps = report.kbps
            applyBitrate(mode: preferences.bitrateMode)
        case .failure(let error):
            Log.warn(.speed, "speed test failed: \(error)")
            lastSpeedTestError = "Speed test failed: \(error)"
        }
    }

    private func applyBitrate(mode: BitrateMode) {
        let kbps = BitratePolicy.targetKbps(
            mode: mode, measuredKbps: measuredKbps, receiverMaxKbps: hello?.maxBitrateKbps ?? 0)
        let changed = kbps != targetKbps
        targetKbps = kbps
        pipeline?.setBitrate(kbps: kbps)
        if changed {
            Log.info(.session, "target bitrate \(kbps / 1000) Mbit/s (\(mode == .auto ? "auto" : "fixed"))")
        }
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    private func refreshStats() {
        guard let connection else { return }
        effectiveBitsPerSecond = connection.bitrateMeter.bitsPerSecond
        framesPerSecond = connection.bitrateMeter.framesPerSecond
        framesSkipped = pipeline?.framesSkipped ?? 0
    }

    // MARK: Helpers

    private static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    /// STREAM_START geometry must not exceed the panel (§6.3).
    private static func clamp(_ size: PixelSize, to hello: Hello) -> PixelSize {
        PixelSize(width: min(size.width, Int(hello.panelWidthPx)), height: min(size.height, Int(hello.panelHeightPx)))
    }

    private static func isHiDPI(_ displayID: CGDirectDisplayID) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return false }
        return mode.pixelWidth > mode.width
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if case CaptureError.permissionDenied = error { return true }
        return false
    }
}
