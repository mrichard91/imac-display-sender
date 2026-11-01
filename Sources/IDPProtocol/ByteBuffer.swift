import Foundation

/// Appends big-endian integers and IDP strings (PROTOCOL §2) to a growing buffer.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ value: UInt8) { data.append(value) }
    public mutating func u16(_ value: UInt16) { appendBigEndian(value) }
    public mutating func u32(_ value: UInt32) { appendBigEndian(value) }
    public mutating func u64(_ value: UInt64) { appendBigEndian(value) }
    public mutating func zeros(_ count: Int) { data.append(contentsOf: repeatElement(0, count: count)) }
    public mutating func bytes(_ bytes: Data) { data.append(bytes) }

    /// `u16 length` + UTF-8 bytes. Text longer than 65 535 bytes is truncated;
    /// every string we send is a short name or log message.
    public mutating func string(_ value: String) {
        let utf8 = Array(value.utf8.prefix(Int(UInt16.max)))
        u16(UInt16(utf8.count))
        data.append(contentsOf: utf8)
    }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Reads big-endian integers and IDP strings from a payload. Works on `Data`
/// slices (non-zero `startIndex`).
public struct ByteReader {
    private let data: Data
    private var offset: Data.Index

    public init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func u8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func u16() throws -> UInt16 { try readBigEndian() }
    public mutating func u32() throws -> UInt32 { try readBigEndian() }
    public mutating func u64() throws -> UInt64 { try readBigEndian() }

    public mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        try require(count)
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    public mutating func string() throws -> String {
        let length = Int(try u16())
        guard remaining >= length else { throw ProtocolError.stringOverflow }
        return String(decoding: try bytes(length), as: UTF8.self)
    }

    /// Everything not read yet.
    public mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data[offset..<data.endIndex]
    }

    private mutating func readBigEndian<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        try require(size)
        var value: T = 0
        for index in offset..<(offset + size) {
            value = value << 8 | T(data[index])
        }
        offset += size
        return value
    }

    private func require(_ count: Int) throws {
        guard remaining >= count else { throw ProtocolError.truncated }
    }
}
