import Foundation

/// Reconnect delays 1, 2, 4, … seconds, capped at 10 s (PROTOCOL §7.2).
public struct ReconnectBackoff: Sendable {
    public let initial: TimeInterval
    public let maximum: TimeInterval
    public private(set) var attempt = 0

    public init(initial: TimeInterval = 1, maximum: TimeInterval = 10) {
        self.initial = initial
        self.maximum = maximum
    }

    /// The delay before the next attempt; each call doubles the following one.
    public mutating func nextDelay() -> TimeInterval {
        let delay = min(maximum, initial * pow(2, Double(min(attempt, 30))))
        attempt += 1
        return delay
    }

    /// Call after a successful handshake.
    public mutating func reset() { attempt = 0 }
}
