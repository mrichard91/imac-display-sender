import Foundation

/// One IDP message (§5).
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case keyframeRequest
    case heartbeat(monoUs: UInt64)
    case stats(Stats)
    case goodbye(Goodbye)
    case ping(Ping)
    case pong(Ping)
    case speedTestResult(SpeedTestResult)
    case streamStart(StreamStart)
    case frame(Frame)
    case streamStop(streamId: UInt32)
    case speedTestStart(SpeedTestStart)
    case speedTestData(SpeedTestData)
    case speedTestEnd(SpeedTestEnd)
    /// A type this implementation does not know. Only the length is kept, so
    /// readers can skip the payload without buffering it (§3).
    case unknown(type: UInt8, length: UInt32)

    public var typeCode: UInt8 {
        switch self {
        case .hello: return MessageType.hello.rawValue
        case .keyframeRequest: return MessageType.keyframeRequest.rawValue
        case .heartbeat: return MessageType.heartbeat.rawValue
        case .stats: return MessageType.stats.rawValue
        case .goodbye: return MessageType.goodbye.rawValue
        case .ping: return MessageType.ping.rawValue
        case .pong: return MessageType.pong.rawValue
        case .speedTestResult: return MessageType.speedTestResult.rawValue
        case .streamStart: return MessageType.streamStart.rawValue
        case .frame: return MessageType.frame.rawValue
        case .streamStop: return MessageType.streamStop.rawValue
        case .speedTestStart: return MessageType.speedTestStart.rawValue
        case .speedTestData: return MessageType.speedTestData.rawValue
        case .speedTestEnd: return MessageType.speedTestEnd.rawValue
        case .unknown(let type, _): return type
        }
    }

    /// Header + payload. `.unknown` encodes as a zero-filled payload of its length.
    public func encode() -> Data {
        var payload = ByteWriter()
        switch self {
        case .hello(let hello): hello.write(to: &payload)
        case .keyframeRequest: break
        case .heartbeat(let monoUs): payload.u64(monoUs)
        case .stats(let stats): stats.write(to: &payload)
        case .goodbye(let goodbye): goodbye.write(to: &payload)
        case .ping(let ping), .pong(let ping): ping.write(to: &payload)
        case .speedTestResult(let result): result.write(to: &payload)
        case .streamStart(let start): start.write(to: &payload)
        case .frame(let frame):
            frame.header.write(to: &payload)
            payload.bytes(frame.accessUnit)
        case .streamStop(let streamId): payload.u32(streamId)
        case .speedTestStart(let start): start.write(to: &payload)
        case .speedTestData(let data): data.write(to: &payload)
        case .speedTestEnd(let end): end.write(to: &payload)
        case .unknown(_, let length): payload.zeros(Int(length))
        }
        var message = ByteWriter(capacity: MessageHeader.size + payload.data.count)
        MessageHeader(type: typeCode, length: UInt32(payload.data.count)).write(to: &message)
        message.bytes(payload.data)
        return message.data
    }

    /// Decodes a payload whose header has already been read. Fixed-size
    /// payloads must have exactly their size; variable ones must not carry
    /// trailing bytes (§9).
    public static func decode(header: MessageHeader, payload: Data) throws -> Message {
        guard payload.count == Int(header.length) else {
            throw ProtocolError.wrongPayloadLength(
                type: header.type, expected: Int(header.length), actual: payload.count)
        }
        guard let type = header.messageType else {
            return .unknown(type: header.type, length: header.length)
        }

        var reader = ByteReader(payload)
        func fixed(_ size: Int) throws {
            guard payload.count == size else {
                throw ProtocolError.wrongPayloadLength(type: header.type, expected: size, actual: payload.count)
            }
        }
        func atLeast(_ size: Int) throws {
            guard payload.count >= size else {
                throw ProtocolError.wrongPayloadLength(type: header.type, expected: size, actual: payload.count)
            }
        }
        func noTrailingBytes() throws {
            guard reader.remaining == 0 else {
                throw ProtocolError.wrongPayloadLength(
                    type: header.type, expected: payload.count - reader.remaining, actual: payload.count)
            }
        }

        let message: Message
        switch type {
        case .hello:
            // protocol_version is the first field in every version; check it
            // before holding the payload to the v1 layout.
            if payload.count >= 2 {
                var peek = ByteReader(payload)
                let version = try peek.u16()
                guard version == protocolVersion else { throw ProtocolError.versionMismatch(version) }
            }
            try atLeast(Hello.fixedSize + 2)
            message = .hello(try Hello(reader: &reader))
            try noTrailingBytes()
        case .keyframeRequest:
            try fixed(0)
            message = .keyframeRequest
        case .heartbeat:
            try fixed(8)
            message = .heartbeat(monoUs: try reader.u64())
        case .stats:
            try fixed(Stats.size)
            message = .stats(try Stats(reader: &reader))
        case .goodbye:
            try atLeast(4)
            message = .goodbye(try Goodbye(reader: &reader))
            try noTrailingBytes()
        case .ping:
            try fixed(Ping.size)
            message = .ping(try Ping(reader: &reader))
        case .pong:
            try fixed(Ping.size)
            message = .pong(try Ping(reader: &reader))
        case .speedTestResult:
            try fixed(SpeedTestResult.size)
            message = .speedTestResult(try SpeedTestResult(reader: &reader))
        case .streamStart:
            try fixed(StreamStart.size)
            message = .streamStart(try StreamStart(reader: &reader))
        case .frame:
            try atLeast(FrameHeader.size)
            let frameHeader = try FrameHeader(reader: &reader)
            message = .frame(Frame(header: frameHeader, accessUnit: reader.rest()))
        case .streamStop:
            try fixed(4)
            message = .streamStop(streamId: try reader.u32())
        case .speedTestStart:
            try fixed(SpeedTestStart.size)
            message = .speedTestStart(try SpeedTestStart(reader: &reader))
        case .speedTestData:
            try atLeast(SpeedTestData.fixedSize)
            message = .speedTestData(try SpeedTestData(reader: &reader))
        case .speedTestEnd:
            try fixed(SpeedTestEnd.size)
            message = .speedTestEnd(try SpeedTestEnd(reader: &reader))
        }
        return message
    }

    /// Decodes one complete message (header + payload) from `bytes`.
    public static func decode(_ bytes: Data) throws -> Message {
        guard bytes.count >= MessageHeader.size else { throw ProtocolError.truncated }
        let header = try MessageHeader.decode(bytes)
        let payloadStart = bytes.startIndex + MessageHeader.size
        let payload = bytes[payloadStart..<bytes.endIndex]
        return try decode(header: header, payload: payload)
    }
}
