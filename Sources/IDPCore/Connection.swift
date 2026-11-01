import Foundation
import IDPProtocol
import Network

/// One IDP connection to a receiver: TCP via Network.framework, framed I/O,
/// HELLO handshake, liveness (§6.5), PING/PONG (§6.8) and the speed test (§6.9).
///
/// All internal state lives on `queue`. Public methods may be called from any
/// thread. `onEvent` is invoked on `queue`; set it before `start()`.
public final class Connection: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Send HEARTBEAT when nothing else was sent for this long. Below the
        /// 500 ms rule so a tick's jitter cannot push a gap over it.
        public var heartbeatIdle: TimeInterval = 0.4
        public var livenessTimeout: TimeInterval = 2.0
        public var helloTimeout: TimeInterval = 3.0
        public var pingInterval: TimeInterval = 1.0
        public var rttWindow = 5
        public var connectTimeoutSeconds = 5
        public var tick: TimeInterval = 0.1

        public init() {}
    }

    public let host: String
    public let port: UInt16
    public let queue: DispatchQueue
    public var onEvent: ((ConnectionEvent) -> Void)?
    /// FRAME bytes (header + payload) actually handed to the socket.
    public let bitrateMeter: BitrateMeter

    private let configuration: Configuration
    private let nw: NWConnection

    private enum State: Equatable { case idle, connecting, awaitingHello, ready, closed }
    private var state = State.idle
    private var reader = FramedReader()
    private var hello: Hello?
    private var link: LinkInfo?
    private var timer: DispatchSourceTimer?
    private var connectedAt: TimeInterval = 0
    private var lastSent: TimeInterval = 0
    private var lastReceived: TimeInterval = 0

    private var nextPingSeq: UInt32 = 1
    private var nextPingAt: TimeInterval = 0
    private var outstandingPings: [UInt32] = []
    private var rtt: RTTTracker

    private var speedTest: SpeedTest?
    private var nextTestId: UInt32 = 1
    /// FRAMEs produced while a speed test runs: never dropped (§8), sent after it.
    private var heldFrames: [(FrameHeader, Data)] = []

    private struct SharedState {
        var pendingFrames = 0
        var speedTestRunning = false
    }
    private let shared = Locked(SharedState())

    public init(host: String, port: UInt16 = defaultPort, configuration: Configuration = Configuration(),
                bitrateMeter: BitrateMeter = BitrateMeter()) {
        self.host = host
        self.port = port
        self.configuration = configuration
        self.bitrateMeter = bitrateMeter
        self.queue = DispatchQueue(label: "idp.connection.\(host):\(port)", qos: .userInteractive)
        rtt = RTTTracker(window: configuration.rttWindow)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = configuration.connectTimeoutSeconds
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData
        nw = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: defaultPort)!,
            using: parameters)
    }

    // MARK: Public API

    public func start() {
        queue.async { [self] in
            guard state == .idle else { return }
            state = .connecting
            Log.info(.net, "connecting to \(host):\(port)")
            nw.stateUpdateHandler = { [weak self] in self?.handleState($0) }
            nw.pathUpdateHandler = { [weak self] path in
                guard let self, self.state != .closed else { return }
                let info = LinkInfo(path: path)
                guard info != self.link else { return }
                self.link = info
                self.emit(.linkChanged(info))
            }
            nw.start(queue: queue)
        }
    }

    /// Encoded FRAMEs queued but not yet written to the socket, including any
    /// held during a speed test. Callers skip captures above 2 (§8).
    public var pendingFrames: Int { shared.value.pendingFrames }

    /// Captures must be skipped while this is true (§6.9).
    public var isSpeedTestRunning: Bool { shared.value.speedTestRunning }

    /// Sends a control message.
    public func send(_ message: Message) {
        let data = message.encode()
        queue.async { [self] in
            guard state == .awaitingHello || state == .ready else { return }
            if case .streamStop = message { discardHeldFrames() }
            write(data)
        }
    }

    /// Sends one FRAME as two writes (prefix + access unit) without copying the AU.
    public func sendFrame(header: FrameHeader, accessUnit: Data) {
        shared.withLock { $0.pendingFrames += 1 }
        queue.async { [self] in
            guard state == .ready else {
                shared.withLock { $0.pendingFrames -= 1 }
                return
            }
            if speedTest != nil {
                heldFrames.append((header, accessUnit))
            } else {
                writeFrame(header, accessUnit)
            }
        }
    }

    /// Runs the §6.9 sender procedure. `completion` is called on `queue`.
    public func runSpeedTest(durationMs: UInt32,
                             completion: @escaping (Result<SpeedTestReport, SpeedTestError>) -> Void) {
        queue.async { [self] in
            guard state == .ready, let hello else { return completion(.failure(.notReady)) }
            guard hello.caps.contains(.speedTest) else { return completion(.failure(.unsupported)) }
            guard speedTest == nil else { return completion(.failure(.alreadyRunning)) }
            guard SpeedTestStart.durationRangeMs.contains(durationMs) else {
                return completion(.failure(.invalidDuration(durationMs)))
            }

            let testId = nextTestId
            nextTestId = nextTestId == UInt32.max ? 1 : nextTestId + 1
            shared.withLock { $0.speedTestRunning = true }
            let test = SpeedTest(
                testId: testId, durationMs: durationMs, link: link, queue: queue,
                write: { [weak self] data, done in self?.write(data, completion: done) },
                completion: { [weak self] result in
                    self?.speedTestFinished()
                    completion(result)
                })
            speedTest = test
            test.start()
        }
    }

    /// Closes the connection. With a reason, sends GOODBYE first (best effort).
    public func close(goodbye reason: GoodbyeReason? = .normal, message: String = "") {
        queue.async { [self] in
            let goodbye = reason.map { Goodbye(reason: $0, message: message) }
            finish(.local(reason ?? .normal, message), goodbye: goodbye)
        }
    }

    // MARK: State

    private func handleState(_ newState: NWConnection.State) {
        guard state != .closed else { return }
        switch newState {
        case .ready:
            guard state == .connecting else { return }
            state = .awaitingHello
            let now = Monotonic.seconds()
            connectedAt = now
            lastReceived = now
            if let path = nw.currentPath { link = LinkInfo(path: path) }
            Log.info(.net, "connected to \(host):\(port) via \(link?.summary ?? "unknown interface")")
            emit(.connected(link ?? LinkInfo(interfaceName: nil, kind: .other, localAddress: nil, remoteAddress: nil)))
            startTimer()
            receiveNext()
        case .waiting(let error), .failed(let error):
            // `.waiting` means no route or refused; our own backoff handles retries.
            finish(.network("cannot connect to \(host):\(port): \(error.localizedDescription)"), goodbye: nil)
        case .cancelled:
            finish(.network("connection cancelled"), goodbye: nil)
        default:
            break
        }
    }

    private func finish(_ reason: DisconnectReason, goodbye: Goodbye?) {
        guard state != .closed else { return }
        let wasOpen = state == .awaitingHello || state == .ready
        state = .closed
        timer?.cancel()
        timer = nil
        speedTest?.cancel(.disconnected)
        heldFrames.removeAll()
        shared.withLock { $0 = SharedState() }
        nw.pathUpdateHandler = nil
        nw.stateUpdateHandler = nil

        if let goodbye, wasOpen {
            Log.info(.net, "sending GOODBYE \(goodbye.reason) and closing")
            let nw = self.nw
            nw.send(content: Message.goodbye(goodbye).encode(), isComplete: true,
                    completion: .contentProcessed { _ in nw.cancel() })
            // Do not let a stalled socket hold the connection open (§6.6: close after GOODBYE).
            queue.asyncAfter(deadline: .now() + 1) { nw.cancel() }
        } else {
            nw.cancel()
        }

        let level: LogLevel = reason.isRetryable ? .warn : .info
        if level == .warn { Log.warn(.net, "disconnected: \(reason)") } else { Log.info(.net, "disconnected: \(reason)") }
        emit(.closed(reason))
        onEvent = nil
    }

    private func emit(_ event: ConnectionEvent) {
        onEvent?(event)
    }

    // MARK: Reading

    private func receiveNext() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.state != .closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Monotonic.seconds()
                do {
                    for message in try self.reader.feed(data) {
                        self.handle(message)
                        if self.state == .closed { return }
                    }
                } catch ProtocolError.versionMismatch(let version) {
                    self.finish(.versionMismatch(version),
                                goodbye: Goodbye(reason: .versionMismatch, message: "sender speaks v\(protocolVersion)"))
                    return
                } catch {
                    let detail = (error as? ProtocolError)?.description ?? "\(error)"
                    Log.error(.net, "protocol error from receiver: \(detail)")
                    self.finish(.protocolError(detail), goodbye: Goodbye(reason: .protocolError, message: detail))
                    return
                }
            }
            if let error {
                self.finish(.network(error.localizedDescription), goodbye: nil)
            } else if isComplete {
                self.finish(.network("receiver closed the connection"), goodbye: nil)
            } else {
                self.receiveNext()
            }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .hello(let hello):
            handleHello(hello)
        case .heartbeat:
            break
        case .ping(let ping):
            write(Message.pong(ping).encode())
        case .pong(let pong):
            handlePong(pong)
        case .goodbye(let goodbye):
            Log.info(.net, "GOODBYE from receiver: \(goodbye.reason) \(goodbye.message)")
            finish(.peerGoodbye(goodbye), goodbye: nil)
        case .speedTestResult(let result):
            if speedTest?.handle(result) != true {
                Log.warn(.speed, "ignoring SPEED_TEST_RESULT for test \(result.testId) (not running)")
            }
        case .keyframeRequest, .stats, .unknown:
            emit(.message(message))
        case .streamStart, .frame, .streamStop, .speedTestStart, .speedTestData, .speedTestEnd:
            Log.warn(.net, String(format: "ignoring sender-only message type 0x%02X from receiver", message.typeCode))
        }
    }

    private func handleHello(_ hello: Hello) {
        guard state == .awaitingHello else {
            Log.warn(.net, "ignoring duplicate HELLO")
            return
        }
        guard hello.protocolVersion == protocolVersion else {
            finish(.versionMismatch(hello.protocolVersion),
                   goodbye: Goodbye(reason: .versionMismatch, message: "sender speaks v\(protocolVersion)"))
            return
        }
        guard hello.codecs.contains(.hevcMain8) else {
            finish(.unsupportedCodec, goodbye: Goodbye(reason: .unsupportedCodec, message: "HEVC Main required"))
            return
        }
        let unknownCaps = hello.caps.subtracting([.canScale, .stats, .speedTest])
        if !unknownCaps.isEmpty {
            Log.warn(.net, "HELLO sets reserved caps bits 0x\(String(unknownCaps.rawValue, radix: 16)); ignoring them")
        }
        state = .ready
        self.hello = hello
        nextPingAt = Monotonic.seconds()
        Log.info(.net, "HELLO from \"\(hello.name)\": \(hello.panelWidthPx)x\(hello.panelHeightPx) @ "
            + String(format: "%.3f Hz", hello.refreshHz) + ", caps 0x\(String(hello.caps.rawValue, radix: 16))")
        emit(.hello(hello))
    }

    private func handlePong(_ pong: Ping) {
        guard let index = outstandingPings.firstIndex(of: pong.seq) else { return }
        outstandingPings.remove(at: index)
        let now = Monotonic.microseconds()
        guard now >= pong.tUs else { return }
        rtt.add(microseconds: now - pong.tUs)
        if let minimum = rtt.minimumMicroseconds { emit(.rttUpdated(microseconds: minimum)) }
    }

    // MARK: Writing

    private func write(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        lastSent = Monotonic.seconds()
        nw.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error, let self, self.state != .closed {
                self.finish(.network("send failed: \(error.localizedDescription)"), goodbye: nil)
            }
            completion?(error == nil)
        })
    }

    private func writeFrame(_ header: FrameHeader, _ accessUnit: Data) {
        let prefix = header.messagePrefix(accessUnitLength: accessUnit.count)
        let total = prefix.count + accessUnit.count
        nw.batch {
            write(prefix)
            write(accessUnit) { [weak self] ok in
                guard let self else { return }
                self.shared.withLock { $0.pendingFrames = max(0, $0.pendingFrames - 1) }
                if ok { self.bitrateMeter.record(bytes: total) }
            }
        }
    }

    /// FRAMEs held by a speed test belong to the stream being stopped. They
    /// cannot be sent before STREAM_STOP (no FRAMEs during a test, §6.9) and
    /// must not follow it (§6.3), so they are dropped.
    private func discardHeldFrames() {
        guard !heldFrames.isEmpty else { return }
        Log.debug(.speed, "discarding \(heldFrames.count) held frame(s) of the stopped stream")
        let count = heldFrames.count
        heldFrames.removeAll()
        shared.withLock { $0.pendingFrames = max(0, $0.pendingFrames - count) }
    }

    private func speedTestFinished() {
        speedTest = nil
        shared.withLock { $0.speedTestRunning = false }
        guard state == .ready else { return }
        let held = heldFrames
        heldFrames.removeAll()
        if !held.isEmpty { Log.debug(.speed, "sending \(held.count) frame(s) held during the test") }
        for (header, accessUnit) in held { writeFrame(header, accessUnit) }
    }

    // MARK: Timers

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.tick, repeating: configuration.tick,
                       leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Monotonic.seconds()
        switch state {
        case .awaitingHello where now - connectedAt > configuration.helloTimeout:
            finish(.helloTimeout, goodbye: Goodbye(reason: .timeout, message: "no HELLO"))
            return
        case .ready where now - lastReceived > configuration.livenessTimeout:
            // Peer presumed gone: no GOODBYE (§6.5).
            finish(.livenessTimeout, goodbye: nil)
            return
        default:
            break
        }

        if state == .ready, now >= nextPingAt {
            nextPingAt = now + configuration.pingInterval
            sendPing()
        }
        if now - lastSent >= configuration.heartbeatIdle {
            write(Message.heartbeat(monoUs: Monotonic.microseconds()).encode())
        }
    }

    private func sendPing() {
        let seq = nextPingSeq
        nextPingSeq &+= 1
        outstandingPings.append(seq)
        if outstandingPings.count > 16 { outstandingPings.removeFirst() }
        write(Message.ping(Ping(seq: seq, tUs: Monotonic.microseconds())).encode())
    }
}
