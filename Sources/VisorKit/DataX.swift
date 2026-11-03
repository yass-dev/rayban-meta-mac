import Foundation

/// DataX message ceiling, imposed by the 14-bit length field.
public let dataXMaxMessage = 16383

/// A parsed DataX message header: the fixed 4 bytes plus extension tags. Port of Visor's `Header.kt`.
public struct MessageInfo: Equatable {
    public var valid = true
    public var hasExtension = false
    public var hasError = false
    public var isClosed = false
    /// The 14-bit payload length. It includes the extension tags.
    public var length = 0
    /// The 16-bit channel id. Its high bit says who opened the channel.
    public var channelId = 0
    public var serviceId = 0
    public var messageType = 0
    public var errorId = 0
    /// 4 plus four per extension tag.
    public var headerLen = 4

    /// Bytes this message occupies on the wire. It is `4 + length`, never `headerLen + length`.
    public var wireTotal: Int { 4 + length }
    /// Application payload bytes, with the extension tags taken out of `length`.
    public var dataLength: Int { length - (headerLen - 4) }
}

public enum DataX {
    public static let tagServiceId = 1
    public static let tagMessageType = 2
    public static let tagErrorId = 3
    public static let tagMessageTypeClosed = 4
    public static let tagQos = 5

    /// The originator bit: set by the side that opened the channel.
    public static let originatorBit = 0x8000
    /// The link setup channel, and its mirror.
    public static let linkSetupChannel = 0x8001
    public static let enableChannel = 0x0001
    /// 0x1000 is the DataX success status every service answers with.
    public static let success = 0x1000
    /// What a peer answers for a service it does not host.
    public static let serviceNotFound = 0xC001

    /// The ack channel for a peer-originated channel: clear the originator bit.
    public static func mirror(_ channelId: Int) -> Int { channelId & 0x7FFF }

    public static func parseHeader(_ buf: [UInt8]) throws -> MessageInfo {
        guard buf.count >= 4 else {
            throw ProtocolFormatError("buffer too short for fixed header: \(buf.count) < 4")
        }
        var info = MessageInfo()
        let b0 = Int(buf[0]), b1 = Int(buf[1]), b2 = Int(buf[2]), b3 = Int(buf[3])
        info.hasExtension = (b0 >> 7) & 1 == 1
        info.length = ((b0 & 0x3F) << 8) | b1
        info.channelId = (b2 << 8) | b3
        if info.hasExtension {
            var offset = 4
            let available = min(buf.count, 4 + info.length)
            var sawLast = false
            while offset + 4 <= available {
                let tagByte = Int(buf[offset])
                let value16 = (Int(buf[offset + 2]) << 8) | Int(buf[offset + 3])
                let continuation = (tagByte >> 7) & 1
                switch tagByte & 0x7F {
                case tagServiceId:
                    info.serviceId = value16
                    if value16 == 0 { info.isClosed = true }
                case tagMessageType:
                    info.messageType = value16
                case tagErrorId:
                    info.errorId = value16
                    info.hasError = true
                case tagMessageTypeClosed:
                    info.messageType = value16
                    info.isClosed = true
                default:
                    break
                }
                info.headerLen += 4
                offset += 4
                if continuation == 0 { sawLast = true; break }
            }
            if !sawLast { info.valid = false }
        }
        return info
    }

    /// Serialise a DataX header: the fixed 4 bytes plus extension tags, in the order service, type, error.
    public static func buildHeader(
        channelId: Int,
        dataLen: Int,
        serviceId: Int? = nil,
        messageType: Int? = nil,
        errorId: Int? = nil
    ) -> [UInt8] {
        var tags: [(Int, Int)] = []
        if let s = serviceId { tags.append((tagServiceId, s & 0xFFFF)) }
        if let t = messageType { tags.append((tagMessageType, t & 0xFFFF)) }
        if let e = errorId { tags.append((tagErrorId, e & 0xFFFF)) }
        let payloadLen = tags.count * 4 + dataLen
        precondition(payloadLen <= dataXMaxMessage, "payload_len \(payloadLen) exceeds the 14-bit maximum")
        let hasExtension = tags.isEmpty ? 0 : 1
        var out: [UInt8] = [
            UInt8((hasExtension << 7) | ((payloadLen >> 8) & 0x3F)),
            UInt8(payloadLen & 0xFF),
            UInt8((channelId >> 8) & 0xFF),
            UInt8(channelId & 0xFF),
        ]
        for (i, (tagId, value)) in tags.enumerated() {
            let continuation = i < tags.count - 1 ? 1 : 0
            out.append(UInt8((continuation << 7) | (tagId & 0x7F)))
            out.append(0)
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return out
    }
}

/// AirShield substream framing: the one-byte outer header on each frame after the handshake.
public enum FrameType: Int {
    /// Encrypted application data.
    case data = 0x40
    /// Cleartext stream control, such as stream 0 LOST.
    case command = 0x80
}

public enum StreamCommand: Int {
    case open = 0, lost = 1, rejected = 2, noRoute = 3, openToAdvertise = 4, connect = 5
}

public enum Framing {
    public static let typeMask = 0xC0
    public static let streamMask = 0x3F

    public static func pack(_ type: FrameType, streamId: Int = 0, body: [UInt8]) -> [UInt8] {
        [UInt8((type.rawValue & typeMask) | (streamId & streamMask))] + body
    }

    public struct Frame { public let type: Int; public let streamId: Int; public let body: [UInt8] }

    public static func unpack(_ data: [UInt8]) throws -> Frame {
        guard let header = data.first else { throw ProtocolFormatError("empty frame") }
        return Frame(type: Int(header) & typeMask, streamId: Int(header) & streamMask, body: Array(data.dropFirst()))
    }
}

/// How long the message starting at these bytes is. Port of Visor's `Sdu.kt`.
public enum Sdu {
    public static let dataXHeader = 4
    public static let airShieldHeader = 10
    public static let aesBlock = 16
    public static let minHead = 2

    public struct Unframeable: Error, CustomStringConvertible {
        public let first: UInt8
        public var description: String { String(format: "cannot frame a message starting with byte 0x%02x", first) }
    }

    /// The total length of the message starting at `head`, or nil if `head` is too short to say yet.
    public static func length(head: [UInt8]) throws -> Int? {
        if head.count < minHead { return nil }
        let first = Int(head[0])
        if first & 0x80 != 0 {
            return dataXHeader + (((first & 0x3F) << 8) | Int(head[1]))
        }
        if first & Framing.typeMask == FrameType.data.rawValue {
            if head.count < airShieldHeader { return nil }
            return airShieldHeader + aesBlock * (Int(head[9]) + 1)
        }
        throw Unframeable(first: head[0])
    }
}
