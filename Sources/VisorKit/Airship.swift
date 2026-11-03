import Foundation

/// svc20, airship: Meta's file transfer engine, the receiving side. Port of `Airship.kt`.
public enum AirshipMsg {
    public static let offer = 1
    public static let cursor = 2
    public static let reset = 3
    public static let data = 4
    public static let check = 5
    public static let complete = 6
    public static let drop = 7
    public static let removed = 8
    public static let queueComplete = 10
    public static let stopped = 11
    public static let offerMultiscope = 12
}

public struct Offer {
    public let raw: [UInt8]
    public let size: UInt64
    public let namespace: String
    public var uuid: String { LinkUuid.format(raw) }
}

/// A whole file. `verified` is true when our adler32 matches the glasses'.
public struct Received {
    public let offer: Offer
    public let file: URL
    public let verified: Bool
}

/// Adler-32 with seed 1, as zlib.
struct Adler32 {
    private var a: UInt32 = 1
    private var b: UInt32 = 0
    var value: UInt32 { (b << 16) | a }

    mutating func update(_ data: [UInt8]) {
        var i = 0
        while i < data.count {
            let n = min(5552, data.count - i)
            for k in i ..< i + n {
                a &+= UInt32(data[k])
                b &+= a
            }
            a %= 65521
            b %= 65521
            i += n
        }
    }

    mutating func reset() { a = 1; b = 0 }
}

/// Hosts svc20 and takes the files the glasses offer, spooling each to `spool`.
public final class AirshipReceiver {
    public static let namespaceMedia = "namespace_media"
    private static let accepted: Set<String> = [namespaceMedia, "bugreport"]
    private static let quiet: Set<String> = ["parfait", "telemetry"]

    private final class Live {
        let offer: Offer
        let file: URL
        var handle: FileHandle
        var adler = Adler32()
        var received: UInt64 = 0
        var startedAt = Date()
        var percent: UInt64 = 0

        init(offer: Offer, file: URL) throws {
            self.offer = offer
            self.file = file
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
        }

        func append(_ chunk: [UInt8]) throws {
            try handle.write(contentsOf: chunk)
            adler.update(chunk)
            received += UInt64(chunk.count)
        }

        func restart() throws {
            try handle.close()
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
            adler.reset()
            received = 0
        }

        func discard() {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }
    }

    private let spool: URL
    private var live: [Int: Live] = [:]
    public var describe: (String) -> String = { _ in "" }
    public var note: (String) -> Void = { _ in }
    public var onReceived: (Received) -> Void = { _ in }
    /// Bytes so far of a file in flight: its asset id, what arrived, its size. Called at most once per percent.
    public var onProgress: (String, UInt64, UInt64) -> Void = { _, _, _ in }
    /// Which offers to take. A refused offer still gets its drop, so the glasses' queue moves on.
    public var accept: (Offer) -> Bool = { _ in true }
    public private(set) var lastActivity = Date.distantPast
    public private(set) var queueEmptyAt = Date.distantPast
    public var inFlight: Int { live.count }

    public init(spool: URL) {
        self.spool = spool
    }

    /// The responder to register on svc20.
    public func respond(_ message: DataXMessage, _ connection: DataXConnection) async throws {
        let channel = message.info.channelId
        lastActivity = Date()
        guard channel & DataX.originatorBit != 0 else { return }
        guard let (type, payload) = try handle(channel: channel, type: message.info.messageType, payload: message.payload) else { return }
        try await connection.send(channel: DataX.mirror(channel), payload: payload, messageType: type)
    }

    /// Let go of every half-received file. Called when the link drops.
    public func abandon() {
        for t in live.values { t.discard() }
        live.removeAll()
    }

    private func handle(channel: Int, type: Int, payload: [UInt8]) throws -> (Int, [UInt8])? {
        switch type {
        case AirshipMsg.offer, AirshipMsg.offerMultiscope:
            let f = Wire.parseLenient(payload)
            let offer = Offer(raw: f.bytes(1), size: f.varint(2), namespace: f.string(3))
            live.removeValue(forKey: channel)?.discard()
            // Refusing still needs the drop, or the glasses' queue stalls behind this offer.
            guard AirshipReceiver.accepted.contains(offer.namespace), accept(offer) else {
                if !AirshipReceiver.quiet.contains(offer.namespace) { note("Refused \(sizeWords(offer.size)) in namespace \"\(offer.namespace)\"") }
                return (AirshipMsg.drop, fileId(offer.raw))
            }
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            live[channel] = try Live(offer: offer, file: spool.appendingPathComponent(offer.uuid))
            note("Receiving \(sizeWords(offer.size))\(describe(offer.uuid))")
            return (AirshipMsg.cursor, cursor(0, 1))

        case AirshipMsg.data:
            if let t = live[channel] {
                try t.append(payload)
                let percent = t.offer.size > 0 ? t.received * 100 / t.offer.size : 0
                if percent != t.percent {
                    t.percent = percent
                    onProgress(t.offer.uuid, t.received, t.offer.size)
                    if t.offer.size > 5_000_000, percent % 25 == 0, percent > 0, percent < 100 {
                        note("\(percent)% of \(sizeWords(t.offer.size))")
                    }
                }
            }

        case AirshipMsg.reset:
            try live[channel]?.restart()

        case AirshipMsg.check:
            if let t = live[channel] { return (AirshipMsg.cursor, cursor(t.received, t.adler.value)) }

        case AirshipMsg.complete:
            guard let t = live.removeValue(forKey: channel) else { return nil }
            try t.handle.close()
            let f = Wire.parseLenient(payload)
            let verified = f.varint(1) == t.received && UInt32(truncatingIfNeeded: f.varint(2)) == t.adler.value
            let seconds = max(0.001, Date().timeIntervalSince(t.startedAt))
            note("Got \(sizeWords(t.received)) in \(String(format: "%.1f", seconds)) s (\(sizeWords(UInt64(Double(t.received) / seconds)))/s)\(verified ? "" : ", checksum mismatch")")
            onReceived(Received(offer: t.offer, file: t.file, verified: verified))
            return (AirshipMsg.drop, fileId(t.offer.raw))

        case AirshipMsg.removed:
            if let t = live.removeValue(forKey: channel) {
                t.discard()
                note("The glasses withdrew a file of \(sizeWords(t.offer.size))")
            }

        case AirshipMsg.stopped:
            let reason = Wire.parseLenient(payload).varint(2)
            if let t = live.removeValue(forKey: channel) {
                t.discard()
                note("The glasses paused a file of \(sizeWords(t.offer.size)) (reason \(reason))")
            }

        case AirshipMsg.queueComplete:
            queueEmptyAt = Date()
            note("The glasses have nothing more queued")

        default:
            break
        }
        return nil
    }

    private func cursor(_ offset: UInt64, _ adler: UInt32) -> [UInt8] {
        Wire.fieldVarintOmitZero(1, offset) + Wire.fieldVarintOmitZero(2, UInt64(adler))
    }

    private func fileId(_ uuid: [UInt8]) -> [UInt8] { Wire.fieldBytes(1, uuid) }
}
