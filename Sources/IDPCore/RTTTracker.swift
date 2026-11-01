import Foundation

/// Link RTT as the minimum of the last few PING round trips (PROTOCOL §6.8):
/// the minimum filters out the peer's queueing delay.
public struct RTTTracker: Sendable {
    public let window: Int
    private var samples: [UInt64] = []

    public init(window: Int = 5) {
        precondition(window > 0)
        self.window = window
    }

    public mutating func add(microseconds: UInt64) {
        samples.append(microseconds)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    public var minimumMicroseconds: UInt64? { samples.min() }

    public mutating func reset() { samples.removeAll() }
}
