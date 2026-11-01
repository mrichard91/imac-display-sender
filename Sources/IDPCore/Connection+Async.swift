import Foundation

extension Connection {
    /// Events as an `AsyncStream`, for scripts and tests. Replaces `onEvent`;
    /// call before `start()`. The stream finishes after `.closed`.
    public func events() -> AsyncStream<ConnectionEvent> {
        AsyncStream { continuation in
            onEvent = { event in
                continuation.yield(event)
                if case .closed = event { continuation.finish() }
            }
        }
    }

    public func speedTest(durationMs: UInt32) async -> Result<SpeedTestReport, SpeedTestError> {
        await withCheckedContinuation { continuation in
            runSpeedTest(durationMs: durationMs) { continuation.resume(returning: $0) }
        }
    }
}
