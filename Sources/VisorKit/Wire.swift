import Foundation

/// Bytes that came off the link cannot be read as the format claims.
public struct ProtocolFormatError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Minimal protobuf-lite primitives: enough to build and parse the link-setup and service
/// messages without a generated stub. Port of Visor's `Wire.kt` and `Proto.kt`.
public enum Wire {

    // MARK: encode

    public static func varint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var remaining = value
        while true {
            let b = UInt8(remaining & 0x7F)
            remaining >>= 7
            out.append(remaining != 0 ? (b | 0x80) : b)
            if remaining == 0 { return out }
        }
    }

    private static func tag(_ field: Int, _ wireType: UInt64) -> [UInt8] {
        varint((UInt64(field) << 3) | wireType)
    }

    /// A varint field. Zero IS written, as the link setup messages need (RequestEncryption field 3).
    public static func fieldVarint(_ field: Int, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    /// A varint field as the firmware's proto3 writers do it: a zero is not written at all.
    public static func fieldVarintOmitZero(_ field: Int, _ value: UInt64) -> [UInt8] {
        value == 0 ? [] : fieldVarint(field, value)
    }

    public static func fieldBytes(_ field: Int, _ value: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(value.count)) + value
    }

    public static func fieldString(_ field: Int, _ value: String) -> [UInt8] {
        fieldBytes(field, Array(value.utf8))
    }

    // MARK: decode

    public static func decodeVarint(_ data: [UInt8], at offset: Int) throws -> (value: UInt64, next: Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var at = offset
        while true {
            guard at < data.count else { throw ProtocolFormatError("truncated varint") }
            let b = data[at]
            at += 1
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            if b & 0x80 == 0 { return (result, at) }
            shift += 7
        }
    }

    /// A parsed flat protobuf message: field number to the values read for it, in wire order.
    public struct Fields {
        public enum Value { case varint(UInt64), bytes([UInt8]) }
        public private(set) var byField: [Int: [Value]] = [:]

        mutating func add(_ field: Int, _ value: Value) {
            byField[field, default: []].append(value)
        }

        /// The first length-delimited value for `field`, or empty.
        public func bytes(_ field: Int) -> [UInt8] {
            for v in byField[field] ?? [] { if case .bytes(let b) = v { return b } }
            return []
        }

        public func string(_ field: Int) -> String {
            String(decoding: bytes(field), as: UTF8.self)
        }

        /// The first varint value for `field`, or 0.
        public func varint(_ field: Int) -> UInt64 {
            for v in byField[field] ?? [] { if case .varint(let n) = v { return n } }
            return 0
        }

        public func repeatedBytes(_ field: Int) -> [[UInt8]] {
            (byField[field] ?? []).compactMap { if case .bytes(let b) = $0 { return b } else { return nil } }
        }

        public func has(_ field: Int) -> Bool { byField[field] != nil }

        public var fieldNumbers: [Int] { byField.keys.sorted() }
    }

    /// Parse a flat protobuf message: varint and length-delimited fields. Fixed32 and fixed64 are skipped.
    public static func parse(_ data: [UInt8]) throws -> Fields {
        var fields = Fields()
        var offset = 0
        let n = data.count
        while offset < n {
            let key = try decodeVarint(data, at: offset)
            offset = key.next
            let field = Int(key.value >> 3)
            switch key.value & 0x07 {
            case 0:
                let v = try decodeVarint(data, at: offset)
                offset = v.next
                fields.add(field, .varint(v.value))
            case 2:
                let len = try decodeVarint(data, at: offset)
                offset = len.next
                let remaining = UInt64(n - offset)
                let take = len.value <= remaining ? Int(len.value) : Int(remaining)
                fields.add(field, .bytes(Array(data[offset ..< offset + take])))
                offset = len.value <= remaining ? offset + take : n
            case 5: offset += 4
            case 1: offset += 8
            default:
                throw ProtocolFormatError("unsupported wire type \(key.value & 7) for field \(field)")
            }
        }
        return fields
    }

    /// Lenient parse for payloads from the glasses: stops at the first thing it cannot read instead of throwing.
    public static func parseLenient(_ data: [UInt8]) -> Fields {
        var fields = Fields()
        var offset = 0
        let n = data.count
        while offset < n {
            guard let key = try? decodeVarint(data, at: offset) else { break }
            offset = key.next
            let field = Int(key.value >> 3)
            switch key.value & 0x07 {
            case 0:
                guard let v = try? decodeVarint(data, at: offset) else { return fields }
                offset = v.next
                fields.add(field, .varint(v.value))
            case 2:
                guard let len = try? decodeVarint(data, at: offset) else { return fields }
                offset = len.next
                guard len.value <= UInt64(n - offset) else { return fields }
                let take = Int(len.value)
                fields.add(field, .bytes(Array(data[offset ..< offset + take])))
                offset += take
            case 5: offset += 4
            case 1: offset += 8
            default: return fields
            }
        }
        return fields
    }
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    public var bytes: [UInt8] { [UInt8](self) }
}
