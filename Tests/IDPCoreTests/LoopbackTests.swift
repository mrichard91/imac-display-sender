import Foundation
import IDPProtocol
import Network
import Testing
@testable import IDPCore

/// A minimal in-process receiver: sends HELLO, answers PING and speed tests,
/// records what it receives.
private final class FakeReceiver: @unchecked Sendable {
    struct Options {
        var caps: Hello.Caps = [.speedTest]
        var sendHello = true
        var sendHeartbeats = true
        var pingSender = false
        var answerPings = true
        /// Sent raw instead of the normal HELLO.
        var rawHello: Data?
    }

    /// One entry per received message; filler is not kept.
    enum Record: Equatable {
        case message(UInt8)
        case speedTestEnd(testId: UInt32, bytesSent: UInt64)
        case goodbye(GoodbyeReason)
        case pong(UInt32)
    }

    let options: Options
    private let queue = DispatchQueue(label: "fake-receiver")
    private let listener: NWListener
    private var connection: NWConnection?
    private var reader = FramedReader()
    private var heartbeat: DispatchSourceTimer?
    private let recorded = Locked<[Record]>([])

    private var activeTest: UInt32?
    private var testBytes: UInt64 = 0
    private var testStart: UInt64 = 0

    init(_ options: Options = Options()) throws {
        self.options = options
        listener = try NWListener(using: .tcp, on: .any)
    }

    var records: [Record] { recorded.value }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { [listener] state in
                let first = resumed.withLock { done -> Bool in defer { done = true }; return !done }
                switch state {
                case .ready where first: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error) where first: continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            heartbeat?.cancel()
            connection?.cancel()
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        if let rawHello = options.rawHello {
            connection.send(content: rawHello, completion: .idempotent)
        } else if options.sendHello {
            send(.hello(Hello(
                caps: options.caps, panelWidthPx: 1920, panelHeightPx: 1080, refreshMhz: 60_000,
                physicalWidthMm: 0, physicalHeightMm: 0, displayId: 7, codecs: .hevcMain8,
                maxBitrateKbps: 0, name: "fake")))
        }
        if options.pingSender { send(.ping(Ping(seq: 77, tUs: 1))) }
        if options.sendHeartbeats {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
            timer.setEventHandler { [weak self] in self?.send(.heartbeat(monoUs: Monotonic.microseconds())) }
            timer.resume()
            heartbeat = timer
        }
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data {
                for message in (try? self.reader.feed(data)) ?? [] { self.handle(message) }
            }
            if !done && error == nil { self.receive() }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .ping(let ping):
            if options.answerPings { send(.pong(ping)) }
            recorded.withLock { $0.append(.message(message.typeCode)) }
        case .pong(let pong):
            recorded.withLock { $0.append(.pong(pong.seq)) }
        case .goodbye(let goodbye):
            recorded.withLock { $0.append(.goodbye(goodbye.reason)) }
        case .speedTestStart(let start):
            activeTest = start.testId
            testBytes = 0
            testStart = Monotonic.microseconds()
            recorded.withLock { $0.append(.message(message.typeCode)) }
        case .speedTestData(let data):
            if data.testId == activeTest { testBytes += UInt64(data.filler.count) }
        case .speedTestEnd(let end):
            recorded.withLock { $0.append(.speedTestEnd(testId: end.testId, bytesSent: end.bytesSent)) }
            guard end.testId == activeTest else { return }
            let elapsed = max(1, Monotonic.microseconds() - testStart)
            send(.speedTestResult(SpeedTestResult(
                testId: end.testId, status: SpeedTestResult.statusOK, bytesReceived: testBytes, elapsedUs: elapsed)))
            activeTest = nil
        case .heartbeat:
            break
        default:
            recorded.withLock { $0.append(.message(message.typeCode)) }
        }
    }

    private func send(_ message: Message) {
        connection?.send(content: message.encode(), completion: .idempotent)
    }
}

/// Collects a connection's events and lets a test wait for one.
private final class EventRecorder: @unchecked Sendable {
    private let events = Locked<[ConnectionEvent]>([])

    init(_ connection: Connection) {
        connection.onEvent = { [events] event in events.withLock { $0.append(event) } }
    }

    func wait<T>(timeout: TimeInterval = 5, _ match: (ConnectionEvent) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = events.value.lazy.compactMap(match).first { return found }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TimeoutError()
    }

    struct TimeoutError: Error {}
}

private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@Suite("Loopback", .serialized)
struct LoopbackTests {
    private func fastConfiguration() -> Connection.Configuration {
        var configuration = Connection.Configuration()
        configuration.pingInterval = 0.1
        return configuration
    }

    @Test func handshakePingSpeedTestAndGoodbye() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port, configuration: fastConfiguration())
        let recorder = EventRecorder(connection)
        connection.start()

        let link = try await recorder.wait { if case .connected(let link) = $0 { link } else { nil } }
        #expect(link.kind == .loopback)
        let hello = try await recorder.wait { if case .hello(let hello) = $0 { hello } else { nil } }
        #expect(hello.name == "fake")
        #expect(hello.caps.contains(.speedTest))

        let rtt = try await recorder.wait { if case .rttUpdated(let us) = $0 { us } else { nil } }
        #expect(rtt < 1_000_000)

        // A FRAME submitted during the test is held until the result arrives.
        let result = Locked<Result<SpeedTestReport, SpeedTestError>?>(nil)
        connection.runSpeedTest(durationMs: 300) { outcome in result.withLock { $0 = outcome } }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(connection.isSpeedTestRunning)
        connection.sendFrame(header: FrameHeader(ptsUs: 1, isKeyframe: true), accessUnit: Data([0, 0, 0, 1, 0x40]))
        #expect(connection.pendingFrames == 1)

        #expect(try await eventually { result.value != nil })
        let report = try #require(try result.value?.get())
        #expect(report.bytesSent > 0)
        #expect(report.bytesReceived == report.bytesSent)
        #expect(report.kbps > 0)
        #expect(report.link?.kind == .loopback)
        #expect(!connection.isSpeedTestRunning)

        let frameType = MessageType.frame.rawValue
        #expect(try await eventually { receiver.records.contains(.message(frameType)) })
        let records = receiver.records
        let endIndex = try #require(records.firstIndex { if case .speedTestEnd = $0 { true } else { false } })
        let frameIndex = try #require(records.firstIndex(of: .message(frameType)))
        #expect(frameIndex > endIndex, "FRAME must not be sent during a speed test")
        #expect(records.contains(.speedTestEnd(testId: 1, bytesSent: report.bytesSent)))
        #expect(try await eventually { connection.pendingFrames == 0 })
        #expect(connection.bitrateMeter.framesPerSecond > 0)

        connection.close(goodbye: .normal)
        let reason = try await recorder.wait { if case .closed(let reason) = $0 { reason } else { nil } }
        #expect(reason == .local(.normal, ""))
        #expect(!reason.isRetryable)
        #expect(try await eventually { receiver.records.contains(.goodbye(.normal)) })
    }

    @Test func streamStopDropsFramesHeldBySpeedTest() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port, configuration: fastConfiguration())
        let recorder = EventRecorder(connection)
        connection.start()
        _ = try await recorder.wait { if case .hello(let hello) = $0 { hello } else { nil } }

        let result = Locked<Result<SpeedTestReport, SpeedTestError>?>(nil)
        connection.runSpeedTest(durationMs: 300) { outcome in result.withLock { $0 = outcome } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let accessUnit = Data([0, 0, 0, 1, 0x40])
        connection.sendFrame(header: FrameHeader(ptsUs: 1, isKeyframe: true), accessUnit: accessUnit)
        connection.send(.streamStop(streamId: 1))
        connection.send(.streamStart(StreamStart(
            hiDPI: false, widthPx: 1920, heightPx: 1080, fpsMhz: 60_000, streamId: 2)))
        connection.sendFrame(header: FrameHeader(ptsUs: 2, isKeyframe: true), accessUnit: accessUnit)
        #expect(try await eventually { result.value != nil })

        let frameType = MessageType.frame.rawValue
        #expect(try await eventually { receiver.records.contains(.message(frameType)) })
        #expect(try await eventually { connection.pendingFrames == 0 })
        let records = receiver.records
        let startIndex = try #require(records.firstIndex(of: .message(MessageType.streamStart.rawValue)))
        let frameIndices = records.indices.filter { records[$0] == .message(frameType) }
        #expect(frameIndices.count == 1, "the old stream's held FRAME must be dropped")
        #expect(frameIndices.allSatisfy { $0 > startIndex })
        connection.close()
    }

    @Test func helloOfAnotherVersionIsVersionMismatch() async throws {
        var options = FakeReceiver.Options()
        options.rawHello = Data([0x01, 0, 0, 0, 0, 0, 0, 4, 0x00, 0x02, 0xAB, 0xCD])
        let receiver = try FakeReceiver(options)
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port)
        let recorder = EventRecorder(connection)
        connection.start()
        let reason = try await recorder.wait { if case .closed(let reason) = $0 { reason } else { nil } }
        #expect(reason == .versionMismatch(2))
        #expect(!reason.isRetryable)
        #expect(try await eventually { receiver.records.contains(.goodbye(.versionMismatch)) })
    }

    @Test func answersPeerPing() async throws {
        var options = FakeReceiver.Options()
        options.pingSender = true
        let receiver = try FakeReceiver(options)
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port)
        let recorder = EventRecorder(connection)
        connection.start()
        _ = try await recorder.wait { if case .hello(let hello) = $0 { hello } else { nil } }
        #expect(try await eventually { receiver.records.contains(.pong(77)) })
        connection.close()
    }

    @Test func speedTestNeedsCapsBit() async throws {
        var options = FakeReceiver.Options()
        options.caps = []
        let receiver = try FakeReceiver(options)
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port)
        let recorder = EventRecorder(connection)
        connection.start()
        _ = try await recorder.wait { if case .hello(let hello) = $0 { hello } else { nil } }
        #expect(await connection.speedTest(durationMs: 500) == .failure(.unsupported))
        #expect(await connection.speedTest(durationMs: 50) == .failure(.unsupported))
        connection.close()
    }

    @Test func detectsSilentReceiver() async throws {
        var options = FakeReceiver.Options()
        options.sendHeartbeats = false
        options.answerPings = false
        let receiver = try FakeReceiver(options)
        defer { receiver.stop() }
        let port = try await receiver.start()

        let connection = Connection(host: "127.0.0.1", port: port)
        let recorder = EventRecorder(connection)
        connection.start()
        _ = try await recorder.wait { if case .hello(let hello) = $0 { hello } else { nil } }
        let reason = try await recorder.wait(timeout: 6) { if case .closed(let reason) = $0 { reason } else { nil } }
        #expect(reason == .livenessTimeout)
        #expect(reason.isRetryable)
    }

    @Test func helloTimeout() async throws {
        var options = FakeReceiver.Options()
        options.sendHello = false
        let receiver = try FakeReceiver(options)
        defer { receiver.stop() }
        let port = try await receiver.start()

        var configuration = Connection.Configuration()
        configuration.helloTimeout = 0.3
        let connection = Connection(host: "127.0.0.1", port: port, configuration: configuration)
        let recorder = EventRecorder(connection)
        connection.start()
        let reason = try await recorder.wait { if case .closed(let reason) = $0 { reason } else { nil } }
        #expect(reason == .helloTimeout)
        #expect(reason.isRetryable)
        #expect(try await eventually { receiver.records.contains(.goodbye(.timeout)) })
    }

    @Test func refusedConnectionIsRetryable() async throws {
        // Grab a free port, then close the listener so nothing is there.
        let receiver = try FakeReceiver()
        let port = try await receiver.start()
        receiver.stop()

        let connection = Connection(host: "127.0.0.1", port: port)
        let recorder = EventRecorder(connection)
        connection.start()
        let reason = try await recorder.wait { if case .closed(let reason) = $0 { reason } else { nil } }
        guard case .network = reason else {
            Issue.record("expected a network error, got \(reason)")
            return
        }
        #expect(reason.isRetryable)
    }
}
