import Foundation

/// Framing: every message is `[u32 length][u8 type][payload]`, big-endian,
/// where `length` counts the type byte plus the payload.
enum ProtocolError: Error, Equatable {
    case truncated
    case frameTooLarge(Int)
}

enum Message {
    /// One framed message: length prefix, type byte, payload.
    static func make(_ type: MsgType, _ body: (inout ByteWriter) -> Void = { _ in }) -> Data {
        var payload = ByteWriter()
        payload.u8(type.rawValue)
        body(&payload)
        var framed = ByteWriter()
        framed.u32(UInt32(payload.data.count))
        framed.raw(payload.data)
        return framed.data
    }
}

/// Reassembles messages from a TCP byte stream.
struct MessageParser {
    private var buffer = Data()
    /// Start of the bytes not consumed yet. Consumed bytes are dropped in
    /// batches, not after every message, so a burst stays linear.
    private var offset = 0

    /// Appends `chunk` and returns every message it completes. Throws when
    /// a length prefix exceeds `Pult.maxMessageSize`; the stream is then
    /// unusable and the connection should be closed.
    mutating func feed(_ chunk: Data) throws -> [(MsgType, Data)] {
        buffer.append(chunk)
        var messages: [(MsgType, Data)] = []
        while buffer.count - offset >= 4 {
            let start = buffer.startIndex + offset
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Pult.maxMessageSize else { throw ProtocolError.frameTooLarge(length) }
            guard buffer.count - offset >= 4 + length else { break }
            if length > 0, let type = MsgType(rawValue: buffer[start + 4]) {
                messages.append((type, buffer.subdata(in: (start + 5)..<(start + 4 + length))))
            }
            offset += 4 + length
        }
        if offset == buffer.count || offset > 1 << 20 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + offset)
            offset = 0
        }
        return messages
    }
}

struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func raw(_ d: Data) { data.append(d) }
    /// Up to 65535 bytes behind a u16 length.
    mutating func blob16(_ d: Data) {
        let capped = d.prefix(Int(UInt16.max))
        u16(UInt16(capped.count))
        data.append(capped)
    }
    mutating func string(_ s: String) { blob16(Data(s.utf8)) }
}

struct ByteReader {
    private let data: Data
    private var position: Int

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    var remaining: Int { data.endIndex - position }

    mutating func u8() throws -> UInt8 { try integer() }
    mutating func u16() throws -> UInt16 { try integer() }
    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func blob16() throws -> Data { try take(Int(try u16())) }
    mutating func string() throws -> String { String(decoding: try blob16(), as: UTF8.self) }

    /// Everything left; the payload tail of variable-length messages.
    mutating func rest() -> Data {
        defer { position = data.endIndex }
        return Data(data[position...])
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard remaining >= count else { throw ProtocolError.truncated }
        defer { position += count }
        return Data(data[position..<position + count])
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        try take(MemoryLayout<T>.size).reduce(T(0)) { $0 << 8 | T($1) }
    }
}
