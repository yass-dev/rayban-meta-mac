import Foundation

/// svc18, media management: lists the captures and re-queues one onto airship. Port of `Captures.kt`.
public enum MediaService {
    public static let enumerate = 1
    public static let listDone = 2
    public static let delete = 3
    public static let deleteOk = 4
    public static let deleteFail = 5
    public static let capture = 6
    public static let captureRetry = 0x80
    public static let captureFound = 0x81
    public static let captureGone = 0x82
    public static let assetRequest = 0x83
    public static let assetFound = 0x84
    public static let assetGone = 0x85
    public static let linkChange = 0x86
    public static let linkChangeOk = 0x87

    /// Link type 1 is the Bluetooth link already up. Link 7 is HIGH: Wi-Fi.
    public static let linkBluetooth = 1
    public static let linkWifi = 7
}

public struct Asset: Equatable {
    public let id: String
    public let typeCode: UInt64
    public let size: UInt64

    /// The low byte: 1 video, 2 still, 3 IMU log, 4 frame log.
    public var kind: Int { Int(typeCode & 0xFF) }
    /// Set once the glasses have handed the asset to a phone.
    public var delivered: Bool { typeCode & 0x100000 != 0 }
}

public enum CaptureType: String { case photo, live, video, other }

/// One entry of the glasses' list.
public struct Capture {
    public let handle: String
    public let kindCode: UInt64
    public var assets: [Asset]
    public let timestampNs: Int64
    public let landscape: Bool

    static let kindVideo: UInt64 = 3074
    static let kindPhoto: UInt64 = 3073

    private var stills: [Asset] { assets.filter { $0.kind == 2 }.sorted { $0.size < $1.size } }

    /// The full-resolution still. A video's only still is its poster, not a photo.
    public var still: Asset? { kindCode == Capture.kindVideo || stills.count < 2 ? nil : stills.last }

    public var type: CaptureType {
        if kindCode == Capture.kindVideo { return .video }
        if still != nil { return assets.contains { $0.kind == 1 } ? .live : .photo }
        if assets.contains(where: { $0.kind == 1 }) { return .video }
        return .other
    }

    public var isMedia: Bool { type != .other }

    /// The video, or the photo's still.
    public var main: Asset? {
        switch type {
        case .video: return assets.filter { $0.kind == 1 }.max { $0.size < $1.size }
        case .photo, .live: return still
        case .other: return nil
        }
    }

    /// A live photo's clip.
    public var motion: Asset? { type == .live ? assets.filter { $0.kind == 1 }.max { $0.size < $1.size } : nil }
    public var imu: Asset? { assets.first { $0.kind == 3 } }
    public var frames: Asset? { assets.first { $0.kind == 4 } }
    /// Everything an import keeps: the photo or video, a live photo's clip, and the two sensor logs.
    public var wanted: [Asset] { isMedia ? [main, motion, imu, frames].compactMap { $0 } : [] }
    /// The small JPEG the glasses make of every capture.
    public var preview: Asset? { stills.first }
    /// The main asset has not gone to any phone yet.
    public var isNew: Bool { main.map { !$0.delivered } ?? false }

    public var takenAt: Date? {
        let ms = timestampNs / 1_000_000
        guard ms > 1_577_836_800_000, ms < 4_102_444_800_000 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public mutating func markDelivered(_ assetId: String) {
        assets = assets.map { $0.id == assetId ? Asset(id: $0.id, typeCode: $0.typeCode | 0x100000, size: $0.size) : $0 }
    }
}

extension GlassesSession {
    /// Ask for the capture list. Each capture comes back on its own as type 6, then type 2 ends the list.
    public func listCaptures(timeout: TimeInterval = 30) async throws -> [Capture] {
        var captures: [Capture] = []
        var done = false
        let gate = AsyncLock()
        let collect: Responder = { message, _ in
            await gate.withLock {
                switch message.info.messageType {
                case MediaService.capture:
                    if let c = CaptureParser.parse(message.payload) {
                        captures.removeAll { $0.handle == c.handle }
                        captures.append(c)
                    }
                case MediaService.listDone:
                    done = true
                default: break
                }
            }
        }
        addResponder(ServiceIds.media, collect)
        defer { removeResponder(ServiceIds.media) }
        _ = try await request(service: ServiceIds.media, type: MediaService.enumerate, expect: [MediaService.listDone], timeout: timeout)
        return await gate.withLock { done ? captures.sorted { $0.timestampNs > $1.timestampNs } : captures }
    }

    /// Put a whole capture back on the airship queue for `linkType`: payload `<handle>:<linkType>`.
    public func requestCapture(_ handle: String, linkType: Int) async throws {
        try await send(service: ServiceIds.media, type: MediaService.linkChange, payload: Array("\(handle):\(linkType)".utf8))
    }

    /// Queue one asset of a capture: payload `<handle>:<assetId>`.
    public func requestAsset(_ handle: String, assetId: String) async throws {
        try await send(service: ServiceIds.media, type: MediaService.assetRequest, payload: Array("\(handle):\(assetId)".utf8))
    }

    /// Delete a capture from the glasses, as the Meta app does once it has one.
    public func deleteCapture(_ handle: String, timeout: TimeInterval = 10) async throws -> Bool {
        let answer = try await request(service: ServiceIds.media, type: MediaService.delete, payload: Array(handle.utf8), expect: [MediaService.deleteOk, MediaService.deleteFail], timeout: timeout)
        return answer.info.messageType == MediaService.deleteOk
    }
}

/// One type 6 flatbuffer. There is no schema, so slots are the ones read off live messages, and every
/// string, table and vector is validated before it is believed.
public enum CaptureParser {
    public static func parse(_ payload: [UInt8]) -> Capture? {
        guard payload.count >= 4 else { return nil }
        let f = Flat(payload)
        let root = Int(f.u32(0))
        guard f.isTable(root) else { return nil }
        guard let info = f.field(root, 4).flatMap(f.target), f.isTable(info) else { return nil }
        guard let handle = f.field(info, 4).flatMap(f.string), !handle.isEmpty else { return nil }
        let assets: [Asset] = (f.field(info, 10).map(f.tables) ?? []).compactMap { pos in
            guard let id = f.field(pos, 4).flatMap(f.string), !id.isEmpty else { return nil }
            return Asset(id: id, typeCode: f.number(f.field(pos, 6)), size: f.number(f.field(pos, 12)))
        }
        let meta = f.field(info, 12).flatMap(f.target).flatMap { f.isTable($0) ? $0 : nil }
        let timestamp = meta.map { Int64(bitPattern: f.number(f.field($0, 4), wide: true)) } ?? 0
        let landscape = meta.map { f.byte(f.field($0, 34)) } == 1
        return Capture(handle: handle, kindCode: f.number(f.field(info, 8)), assets: assets, timestampNs: timestamp, landscape: landscape)
    }

    /// A flatbuffer read by its own vtables.
    struct Flat {
        let b: [UInt8]
        init(_ b: [UInt8]) { self.b = b }

        func fits(_ o: Int, _ need: Int = 0) -> Bool { o >= 0 && o + need <= b.count }
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24) }
        func i32(_ o: Int) -> Int { Int(Int32(bitPattern: u32(o))) }

        func vtable(_ pos: Int) -> (Int, Int)? {
            guard fits(pos, 4) else { return nil }
            let vt = pos - i32(pos)
            guard fits(vt, 4) else { return nil }
            let vtSize = u16(vt), tableSize = u16(vt + 2)
            guard vtSize >= 4, vtSize % 2 == 0, fits(vt, vtSize), tableSize >= 4, fits(pos, tableSize) else { return nil }
            return (vt, vtSize)
        }

        func isTable(_ pos: Int) -> Bool { vtable(pos) != nil }

        func field(_ pos: Int, _ slot: Int) -> Int? {
            guard let (vt, vtSize) = vtable(pos) else { return nil }
            let index = (slot - 4) / 2
            guard index >= 0, 4 + index * 2 + 2 <= vtSize else { return nil }
            let offset = u16(vt + 4 + index * 2)
            guard offset != 0, fits(pos + offset) else { return nil }
            return pos + offset
        }

        func target(_ fp: Int) -> Int? {
            guard fits(fp, 4) else { return nil }
            let o = fp + Int(u32(fp))
            return fits(o, 4) ? o : nil
        }

        func string(_ fp: Int) -> String? {
            guard let o = target(fp) else { return nil }
            let n = Int(u32(o))
            guard n <= 8192, fits(o + 4, n + 1), b[o + 4 + n] == 0 else { return nil }
            return String(bytes: b[(o + 4) ..< (o + 4 + n)], encoding: .utf8)
        }

        func tables(_ fp: Int) -> [Int] {
            guard let o = target(fp) else { return [] }
            let n = Int(u32(o))
            guard n > 0, n <= 4096, fits(o + 4, n * 4) else { return [] }
            var out: [Int] = []
            for k in 0 ..< n {
                let element = o + 4 + k * 4
                let table = element + Int(u32(element))
                guard isTable(table) else { return [] }
                out.append(table)
            }
            return out
        }

        func byte(_ fp: Int?) -> Int { if let fp, fits(fp, 1) { return Int(b[fp]) } else { return 0 } }

        func number(_ fp: Int?, wide: Bool = false) -> UInt64 {
            guard let fp else { return 0 }
            if wide, fits(fp, 8) { return UInt64(u32(fp)) | (UInt64(u32(fp + 4)) << 32) }
            if fits(fp, 4) { return UInt64(u32(fp)) }
            return 0
        }
    }
}

public func sizeWords(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
    return "\(bytes) B"
}
