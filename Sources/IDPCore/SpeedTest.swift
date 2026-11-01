import Foundation
import IDPProtocol

/// Outcome of a successful speed test (PROTOCOL §6.9).
public struct SpeedTestReport: Equatable, Sendable {
    public var testId: UInt32
    public var durationMs: UInt32
    public var bytesSent: UInt64
    public var bytesReceived: UInt64
    public var elapsedUs: UInt64
    /// From the receiver's numbers, which are authoritative.
    public var kbps: UInt64
    public var link: LinkInfo?
    public var date: Date

    public var mbps: Double { Double(kbps) / 1_000 }
}

public enum SpeedTestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported
    case alreadyRunning
    case invalidDuration(UInt32)
    case notReady
    case timeout
    case aborted
    case disconnected

    public var description: String {
        switch self {
        case .unsupported: return "receiver does not support speed tests"
        case .alreadyRunning: return "a speed test is already running"
        case .invalidDuration(let ms): return "duration \(ms) ms is outside 100–10000 ms"
        case .notReady: return "not connected"
        case .timeout: return "no result from receiver"
        case .aborted: return "receiver aborted the test"
        case .disconnected: return "connection closed during the test"
        }
    }
}

/// Sender side of one speed test. Runs entirely on the connection's queue;
/// `Connection` owns it and routes SPEED_TEST_RESULT to it.
final class SpeedTest {
    typealias Write = (_ data: Data, _ completion: ((Bool) -> Void)?) -> Void
    typealias Completion = (Result<SpeedTestReport, SpeedTestError>) -> Void

    static let chunkSize = 1 << 20
    /// ≤ 4 MiB outstanding, so SPEED_TEST_END is not stuck behind a backlog.
    static let maxOutstandingChunks = 4
    static let resultGrace: TimeInterval = 5
    private static let filler = Data(repeating: 0xA5, count: chunkSize)

    let testId: UInt32
    let durationMs: UInt32
    private let queue: DispatchQueue
    private let write: Write
    private let link: LinkInfo?
    private var completion: Completion?

    private enum Phase { case idle, sending, awaitingResult, finished }
    private var phase = Phase.idle
    private var outstanding = 0
    private var bytesSent: UInt64 = 0
    private var sendDeadline: TimeInterval = 0
    private var timers: [DispatchSourceTimer] = []

    init(testId: UInt32, durationMs: UInt32, link: LinkInfo?, queue: DispatchQueue,
         write: @escaping Write, completion: @escaping Completion) {
        self.testId = testId
        self.durationMs = durationMs
        self.link = link
        self.queue = queue
        self.write = write
        self.completion = completion
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .idle else { return }
        Log.info(.speed, "test \(testId): sending for \(durationMs) ms")
        phase = .sending
        write(Message.speedTestStart(SpeedTestStart(testId: testId, durationMs: durationMs)).encode(), nil)
        sendDeadline = Monotonic.seconds() + TimeInterval(durationMs) / 1_000
        // Ends the send phase on time even if no chunk completes (stalled link).
        schedule(after: TimeInterval(durationMs) / 1_000) { [weak self] in self?.pump() }
        pump()
    }

    /// Feeds a SPEED_TEST_RESULT. Returns false if it is not for this test.
    func handle(_ result: SpeedTestResult) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard result.testId == testId, phase != .finished else { return false }
        guard result.isOK else {
            Log.warn(.speed, "test \(testId): receiver aborted")
            finish(.failure(.aborted))
            return true
        }
        guard let kbps = result.throughputKbps else {
            finish(.failure(.aborted))
            return true
        }
        let report = SpeedTestReport(
            testId: testId, durationMs: durationMs, bytesSent: bytesSent,
            bytesReceived: result.bytesReceived, elapsedUs: result.elapsedUs,
            kbps: kbps, link: link, date: Date())
        Log.info(.speed, String(
            format: "test %u: %.1f Mbit/s (%llu bytes in %llu us, sent %llu) over %@",
            testId, report.mbps, result.bytesReceived, result.elapsedUs, bytesSent,
            link?.summary ?? "unknown link"))
        finish(.success(report))
        return true
    }

    func cancel(_ error: SpeedTestError) {
        dispatchPrecondition(condition: .onQueue(queue))
        finish(.failure(error))
    }

    private func pump() {
        guard phase == .sending else { return }
        let now = Monotonic.seconds()
        while now < sendDeadline, outstanding < Self.maxOutstandingChunks {
            outstanding += 1
            bytesSent += UInt64(Self.chunkSize)
            write(SpeedTestData.messagePrefix(testId: testId, fillerLength: Self.chunkSize), nil)
            write(Self.filler) { [weak self] ok in
                guard let self else { return }
                self.outstanding -= 1
                if ok { self.pump() }
            }
        }
        if now >= sendDeadline { sendEnd() }
    }

    private func sendEnd() {
        phase = .awaitingResult
        write(Message.speedTestEnd(SpeedTestEnd(testId: testId, bytesSent: bytesSent)).encode(), nil)
        Log.debug(.speed, "test \(testId): END sent after \(bytesSent) filler bytes; waiting for result")
        schedule(after: TimeInterval(durationMs) / 1_000 + Self.resultGrace) { [weak self] in
            guard let self, self.phase == .awaitingResult else { return }
            Log.warn(.speed, "test \(self.testId): no SPEED_TEST_RESULT in time")
            self.finish(.failure(.timeout))
        }
    }

    private func schedule(after seconds: TimeInterval, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    private func finish(_ result: Result<SpeedTestReport, SpeedTestError>) {
        guard phase != .finished else { return }
        phase = .finished
        timers.forEach { $0.cancel() }
        timers.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}
