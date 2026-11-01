import Foundation

/// Converts VideoToolbox's length-prefixed (HVCC) NAL units into an Annex-B
/// access unit (PROTOCOL §6.2).
public enum AnnexB {
    public static let startCode = Data([0, 0, 0, 1])

    public enum ConversionError: Error, Equatable {
        case invalidLengthSize(Int)
        case truncatedNAL(offset: Int)
    }

    /// Replaces each `nalLengthSize`-byte big-endian length with a 4-byte start
    /// code. `parameterSets` (VPS, SPS, PPS for a keyframe) are prepended, each
    /// with its own start code.
    public static func fromLengthPrefixed(
        _ data: Data, nalLengthSize: Int, parameterSets: [Data] = []
    ) throws -> Data {
        guard [1, 2, 4].contains(nalLengthSize) else {
            throw ConversionError.invalidLengthSize(nalLengthSize)
        }
        let parameterBytes = parameterSets.reduce(0) { $0 + startCode.count + $1.count }
        var output = Data()
        output.reserveCapacity(parameterBytes + data.count + data.count / 64)
        for set in parameterSets {
            output.append(startCode)
            output.append(set)
        }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                guard offset + nalLengthSize <= raw.count else {
                    throw ConversionError.truncatedNAL(offset: offset)
                }
                var length = 0
                for index in 0..<nalLengthSize {
                    length = length << 8 | Int(raw[offset + index])
                }
                let start = offset + nalLengthSize
                guard length > 0, start + length <= raw.count else {
                    throw ConversionError.truncatedNAL(offset: offset)
                }
                output.append(startCode)
                output.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)]))
                offset = start + length
            }
        }
        return output
    }

    /// Splits an Annex-B stream at 3- or 4-byte start codes. For tests and diagnostics.
    public static func nalUnits(in annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var units: [Data] = []
        var unitStart: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                var codeStart = index
                if codeStart > 0, bytes[codeStart - 1] == 0 { codeStart -= 1 }
                if let start = unitStart { units.append(Data(bytes[start..<codeStart])) }
                unitStart = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let start = unitStart, start <= bytes.count { units.append(Data(bytes[start...])) }
        return units
    }

    /// HEVC `nal_unit_type` from the first byte of a NAL unit header.
    public static func hevcNALType(_ nal: Data) -> UInt8? {
        nal.first.map { ($0 >> 1) & 0x3F }
    }
}
