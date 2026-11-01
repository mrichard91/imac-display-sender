import Foundation

/// The host's monotonic clock (`CLOCK_UPTIME_RAW`, the same timebase as
/// `mach_absolute_time` and ScreenCaptureKit sample timestamps).
public enum Monotonic {
    public static func nanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    public static func microseconds() -> UInt64 { nanoseconds() / 1_000 }
    public static func seconds() -> TimeInterval { TimeInterval(nanoseconds()) / 1_000_000_000 }
}
