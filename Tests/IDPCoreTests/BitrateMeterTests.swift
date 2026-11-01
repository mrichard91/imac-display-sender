import Foundation
import Testing
@testable import IDPCore

/// A settable clock for deterministic meter tests.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0

    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

@Suite("BitrateMeter")
struct BitrateMeterTests {
    @Test func emptyMeterReadsZero() {
        let meter = BitrateMeter(clock: { 0 })
        #expect(meter.bitsPerSecond == 0)
        #expect(meter.framesPerSecond == 0)
    }

    @Test func countsBytesAndFramesInsideTheWindow() {
        let clock = FakeClock()
        let meter = BitrateMeter(window: 1, clock: { clock.now })
        for time in [0.1, 0.5, 0.9] {
            clock.now = time
            meter.record(bytes: 1_000)
        }
        clock.now = 1.0
        #expect(meter.bitsPerSecond == 24_000)
        #expect(meter.framesPerSecond == 3)

        // The sample at 0.1 falls out once now - 1 s passes it.
        clock.now = 1.2
        #expect(meter.bitsPerSecond == 16_000)
        #expect(meter.framesPerSecond == 2)

        clock.now = 5
        #expect(meter.bitsPerSecond == 0)
        #expect(meter.framesPerSecond == 0)
    }

    @Test func sampleExactlyAtWindowEdgeIsExcluded() {
        let clock = FakeClock()
        let meter = BitrateMeter(window: 1, clock: { clock.now })
        meter.record(bytes: 500)
        clock.now = 1.0
        #expect(meter.bitsPerSecond == 0)
    }

    @Test func steadyStreamMatchesItsRate() {
        // 60 fps × 125 000 bytes = 60 Mbit/s.
        let clock = FakeClock()
        let meter = BitrateMeter(window: 1, clock: { clock.now })
        for frame in 0..<600 {
            clock.now = Double(frame) / 60
            meter.record(bytes: 125_000)
        }
        #expect(abs(meter.bitsPerSecond - 60_000_000) <= 1_000_000)
        #expect(abs(meter.framesPerSecond - 60) <= 1)
    }

    @Test func resetClears() {
        let meter = BitrateMeter(clock: { 0 })
        meter.record(bytes: 10)
        meter.reset()
        #expect(meter.bitsPerSecond == 0)
    }

    @Test func concurrentRecordsAreNotLost() async {
        let meter = BitrateMeter(window: 1_000, clock: { 0 })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<1_000 { meter.record(bytes: 1) } }
            }
        }
        #expect(meter.framesPerSecond * 1_000 == 8_000)
    }
}
