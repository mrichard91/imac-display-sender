import Foundation

/// A value guarded by a lock, for state shared between the connection queue,
/// capture/encoder callbacks and the main thread.
public final class Locked<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    public init(_ value: Value) { storage = value }

    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}
