import Foundation
import os

/// Component prefixes used in log lines, e.g. `[net]`.
public enum LogComponent: String, Sendable {
    case net, vt, display, capture, speed, ui, session, probe
}

public enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warn, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }

    /// Parses `debug|info|warn|error` (case-insensitive).
    public init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: return nil
        }
    }
}

/// Writes `LEVEL [component] message` to stderr and to the unified log.
/// The minimum level comes from `IDP_LOG_LEVEL` (default info).
public enum Log {
    public static let subsystem = "io.github.mrichard91.imac-display-sender"

    private static let state = Locked<LogLevel>(
        ProcessInfo.processInfo.environment["IDP_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .info)

    public static var minimumLevel: LogLevel {
        get { state.value }
        set { state.withLock { $0 = newValue } }
    }

    public static func debug(_ component: LogComponent, _ message: @autoclosure () -> String) {
        write(.debug, component, message)
    }

    public static func info(_ component: LogComponent, _ message: @autoclosure () -> String) {
        write(.info, component, message)
    }

    public static func warn(_ component: LogComponent, _ message: @autoclosure () -> String) {
        write(.warn, component, message)
    }

    public static func error(_ component: LogComponent, _ message: @autoclosure () -> String) {
        write(.error, component, message)
    }

    private static let stderrLock = NSLock()

    private static func write(_ level: LogLevel, _ component: LogComponent, _ message: () -> String) {
        guard level >= minimumLevel else { return }
        let text = message()
        let line = "\(level.label) [\(component.rawValue)] \(text)\n"
        stderrLock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        stderrLock.unlock()
        Logger(subsystem: subsystem, category: component.rawValue)
            .log(level: level.osLogType, "\(text, privacy: .public)")
    }
}
