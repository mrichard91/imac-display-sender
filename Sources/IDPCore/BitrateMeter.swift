import Foundation

/// Effective bitrate and frame rate over a sliding window (default 1 s) of
/// bytes actually written to the socket. Thread-safe.
public final class BitrateMeter: @unchecked Sendable {
    public typealias Clock = @Sendable () -> TimeInterval

    public let window: TimeInterval
    private let clock: Clock
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int)] = []
    private var head = 0
    private var bytesInWindow = 0

    public init(window: TimeInterval = 1, clock: @escaping Clock = { Monotonic.seconds() }) {
        precondition(window > 0)
        self.window = window
        self.clock = clock
    }

    /// Records one frame of `bytes` (header + payload) written now.
    public func record(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        samples.append((clock(), bytes))
        bytesInWindow += bytes
        prune(now: clock())
    }

    public var bitsPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        prune(now: clock())
        return Double(bytesInWindow) * 8 / window
    }

    public var framesPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        prune(now: clock())
        return Double(samples.count - head) / window
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        head = 0
        bytesInWindow = 0
    }

    /// Drops samples at or before `now - window`. Caller holds the lock.
    private func prune(now: TimeInterval) {
        let cutoff = now - window
        while head < samples.count, samples[head].time <= cutoff {
            bytesInWindow -= samples[head].bytes
            head += 1
        }
        if head > 256, head * 2 > samples.count {
            samples.removeFirst(head)
            head = 0
        }
    }
}
