import Foundation
import IDPProtocol

/// Turns an arbitrary sequence of TCP reads into messages (PROTOCOL §4).
/// Handles headers and payloads split across reads, several messages in one
/// read, and skips unknown types without buffering their payloads (§3).
public struct FramedReader {
    private var buffer = Data()
    private var header: MessageHeader?
    private var skipRemaining = 0
    private var reservedHeaderBitsSeen = 0

    public init() {}

    /// Bytes held waiting for the rest of a message.
    public var bufferedByteCount: Int { buffer.count }

    /// Feeds one read. Throws `ProtocolError` on a malformed message; the
    /// reader is unusable afterwards and the connection must be closed.
    public mutating func feed(_ chunk: Data) throws -> [Message] {
        var input = chunk
        var messages: [Message] = []

        while true {
            if skipRemaining > 0 {
                let skipped = min(skipRemaining, input.count)
                input = input.dropFirst(skipped)
                skipRemaining -= skipped
                if skipRemaining > 0 { return messages }
            }
            if !input.isEmpty {
                buffer.append(input)
                input = Data()
            }

            if header == nil {
                guard buffer.count >= MessageHeader.size else { return messages }
                let next = try MessageHeader.decode(buffer.prefix(MessageHeader.size))
                consume(MessageHeader.size)
                if next.flags != 0 || next.reserved != 0 { logReservedHeaderBits(next) }
                if next.messageType == nil {
                    messages.append(.unknown(type: next.type, length: next.length))
                    let available = min(Int(next.length), buffer.count)
                    consume(available)
                    skipRemaining = Int(next.length) - available
                    continue
                }
                header = next
            }

            guard let current = header, buffer.count >= Int(current.length) else { return messages }
            let payload = Data(buffer.prefix(Int(current.length)))
            consume(Int(current.length))
            header = nil
            messages.append(try Message.decode(header: current, payload: payload))
        }
    }

    /// Tolerated but logged (§9); rate-limited so a peer that always sets
    /// them cannot flood the log.
    private mutating func logReservedHeaderBits(_ header: MessageHeader) {
        reservedHeaderBitsSeen += 1
        guard reservedHeaderBitsSeen == 1 || reservedHeaderBitsSeen % 1000 == 0 else { return }
        Log.warn(.net, String(format: "type 0x%02X header has hflags 0x%02X reserved 0x%04X; ignoring (%d so far)",
                              header.type, header.flags, header.reserved, reservedHeaderBitsSeen))
    }

    private mutating func consume(_ count: Int) {
        if count == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeFirst(count)
        }
    }
}
