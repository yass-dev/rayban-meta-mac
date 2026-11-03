import Foundation

/// svc33, RLDrive: the replicated store the glasses keep their settings in. Every setting is a kv object whose
/// uri is the key and whose data is the value as text. Port of Visor's `RlDrive.kt`.
public enum RlDrive {
    public static let serviceId = 33
    /// The one DataX message type both ways; RLDriveMessage field 1 says whether it is whole or a chunk.
    public static let syncMessage = 1

    static let typeSyncMessage: UInt64 = 1
    static let typeChunkedSyncMessage: UInt64 = 5
    static let apiVersion: UInt64 = 1

    public static let typeKv = "kv"
    static let allTypes = [typeKv, "sync_metadata", "media"]

    /// Our writer id, shaped like the glasses' own. Reads claim it at version 0; writes count it up.
    public static let localWriter = "5f1c0de0-7615-4a0e-9d1e-000000000001"

    /// The two namespaces named after the device, `<uuid>@<name>`; the bare name reads as empty.
    public static let scopedNamespaces = ["individual_device_settings", "individual_device_sensitive_settings"]
    public static let deviceNamespaces = ["local_device_settings", "shared_settings_namespace_1"]

    /// The name to sync for `base`: scoped ones carry the device uuid.
    public static func namespace(_ base: String, deviceUuid: String) -> String {
        scopedNamespaces.contains(base) && !deviceUuid.isEmpty ? "\(deviceUuid)@\(base)" : base
    }
}

/// Writer id to counter, per object type, in the order the glasses sent them.
public struct DriveVersions: Equatable {
    public struct Writer: Equatable {
        public var id: String
        public var version: Int64
        public init(_ id: String, _ version: Int64) { self.id = id; self.version = version }
    }

    public struct ForType: Equatable {
        public var type: String
        public var writers: [Writer]
        public init(_ type: String, _ writers: [Writer]) { self.type = type; self.writers = writers }
    }

    public var types: [ForType]
    public init(_ types: [ForType] = []) { self.types = types }

    public var isEmpty: Bool { types.isEmpty }
    public var typeNames: [String] { types.map(\.type) }
    public func writers(_ type: String) -> [Writer] { types.first { $0.type == type }?.writers ?? [] }
}

/// An object to hand the glasses as another replica of a namespace would; `data` is the type's own encoding.
public struct DrivePush: Equatable {
    public let uri: String
    public let type: String
    public let data: [UInt8]
    public let deleted: Bool

    public init(uri: String, type: String = RlDrive.typeKv, data: [UInt8], deleted: Bool = false) {
        self.uri = uri; self.type = type; self.data = data; self.deleted = deleted
    }

    public static func kv(_ key: String, _ text: String) -> DrivePush { DrivePush(uri: key, data: Array(text.utf8)) }
}

/// One RLDriveObject as read. `raw` is the whole InternalObject.
public struct DriveObject: Equatable {
    public let uri: String
    public let type: String
    public let data: String
    public let deleted: Bool
    public let raw: [UInt8]
}

public struct DriveSyncReply: Equatable {
    public let namespace: String
    public let round: Int64
    public let terminated: Bool
    public let requestId: String
    public let versions: DriveVersions
    public let objects: [DriveObject]
}

extension RlDrive {
    private static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    /// One SYNC_MESSAGE. Round 0 claims `known` plus ourselves at 0: nothing known asks for everything. Round 2
    /// echoes their versions and carries `push`, each object one step of our writer's counter.
    public static func buildSync(
        namespace: String, requestId: String, round: Int64, known: DriveVersions = DriveVersions(),
        types: [String]? = nil, push: [DrivePush] = []
    ) -> [UInt8] {
        let wanted = types ?? distinct(allTypes + known.typeNames)
        var sync: [UInt8] = []
        for type in distinct(wanted + push.map(\.type)) {
            var writers = known.writers(type)
            let base = writers.first { $0.id == localWriter }?.version ?? 0
            let mine = round == 0 ? [] : push.filter { $0.type == type }
            let own = round == 0 ? 0 : base + Int64(mine.count)
            if let i = writers.firstIndex(where: { $0.id == localWriter }) {
                writers[i].version = own
            } else {
                writers.append(.init(localWriter, own))
            }
            var typeData: [UInt8] = []
            for w in writers {
                typeData += Wire.fieldBytes(11, Wire.fieldString(1, w.id) + Wire.fieldVarint(2, UInt64(bitPattern: w.version)))
            }
            typeData += Wire.fieldString(12, type)
            for (i, o) in mine.enumerated() {
                let object = Wire.fieldString(1, o.uri) + Wire.fieldString(2, o.type) + Wire.fieldBytes(3, o.data)
                    + (o.deleted ? Wire.fieldVarint(8, 1) : [])
                let version = Wire.fieldString(1, localWriter) + Wire.fieldVarint(2, UInt64(bitPattern: base + Int64(i) + 1))
                typeData += Wire.fieldBytes(13, Wire.fieldBytes(6, object) + Wire.fieldBytes(7, version))
            }
            sync += Wire.fieldBytes(16, typeData)
        }
        sync += Wire.fieldVarint(17, UInt64(bitPattern: round))
            + Wire.fieldString(18, requestId)
            + Wire.fieldVarint(19, apiVersion)
            + Wire.fieldString(20, namespace)
            + Wire.fieldString(21, localWriter)
        return Wire.fieldVarint(1, typeSyncMessage) + Wire.fieldBytes(2, sync) + Wire.fieldString(6, namespace)
    }

    /// `message` as the glasses send theirs: whole up to `max` bytes of SyncMessage, beyond that
    /// CHUNKED_SYNC_MESSAGE slices tied by `chunkId` and counted from 0.
    public static func chunks(_ message: [UInt8], max: Int = 1024, chunkId: String = UUID().uuidString.lowercased()) -> [[UInt8]] {
        let outer = Wire.parseLenient(message)
        let data = outer.bytes(2)
        if data.count <= max { return [message] }
        let slices = stride(from: 0, to: data.count, by: max).map { Array(data[$0 ..< Swift.min($0 + max, data.count)]) }
        return slices.enumerated().map { i, slice in
            Wire.fieldVarint(1, typeChunkedSyncMessage) + Wire.fieldBytes(2, slice) + Wire.fieldString(5, chunkId)
                + Wire.fieldBytes(6, outer.bytes(6)) + Wire.fieldVarint(7, UInt64(slices.count)) + Wire.fieldVarint(8, UInt64(i))
        }
    }

    public static func decodeSync(_ payload: [UInt8]) -> DriveSyncReply {
        let outer = Wire.parseLenient(payload)
        let sync = Wire.parseLenient(outer.bytes(2))
        var versions = DriveVersions()
        var objects: [DriveObject] = []
        for blob in sync.repeatedBytes(16) {
            let typeData = Wire.parseLenient(blob)
            let type = text(typeData.bytes(12))
            let writers = typeData.repeatedBytes(11).map { entry -> DriveVersions.Writer in
                let e = Wire.parseLenient(entry)
                return .init(text(e.bytes(1)), Int64(bitPattern: e.varint(2)))
            }
            if let i = versions.types.firstIndex(where: { $0.type == type }) {
                versions.types[i].writers = writers
            } else {
                versions.types.append(.init(type, writers))
            }
            for inner in typeData.repeatedBytes(13) {
                let object = Wire.parseLenient(Wire.parseLenient(inner).bytes(6))
                guard object.has(1) else { continue }
                objects.append(DriveObject(
                    uri: text(object.bytes(1)), type: text(object.bytes(2)), data: text(object.bytes(3)),
                    deleted: object.varint(8) != 0, raw: inner
                ))
            }
        }
        return DriveSyncReply(
            namespace: text(outer.bytes(6)), round: Int64(bitPattern: sync.varint(17)), terminated: sync.varint(22) != 0,
            requestId: text(sync.bytes(18)), versions: versions, objects: objects
        )
    }

    private static func distinct(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

/// Joins CHUNKED_SYNC_MESSAGE pieces by chunk id. A whole message passes straight through.
public final class RlDriveAssembler {
    private var parts: [String: [UInt64: [UInt8]]] = [:]
    private let lock = NSLock()

    public init() {}

    /// The whole RLDriveMessage once every piece is in, else nil.
    public func assemble(_ payload: [UInt8]) -> [UInt8]? {
        let f = Wire.parseLenient(payload)
        let total = f.varint(7)
        if f.varint(1) != RlDrive.typeChunkedSyncMessage || total <= 1 { return payload }
        let id = String(decoding: f.bytes(5), as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        // The glasses leave the index out on their first piece: a missing field reads as 0.
        parts[id, default: [:]][f.varint(8)] = f.bytes(2)
        guard let chunks = parts[id], UInt64(chunks.count) >= total else { return nil }
        parts[id] = nil
        let data = chunks.keys.sorted().flatMap { chunks[$0]! }
        return Wire.fieldVarint(1, RlDrive.typeSyncMessage) + Wire.fieldBytes(2, data) + Wire.fieldBytes(6, f.bytes(6))
    }
}

/// What one namespace gave in a sync.
struct DriveNamespaceRead {
    var answered = false
    var finished = false
    var versions = DriveVersions()
    var objects: [DriveObject] = []

    /// kv objects as key to text; deleted ones are left out.
    var kv: [String: String] {
        var out: [String: String] = [:]
        for o in objects where o.type == RlDrive.typeKv {
            if o.deleted { out[o.uri] = nil } else { out[o.uri] = o.data }
        }
        return out
    }
}

/// The state of one sync across its namespaces, filled by the svc33 responder on the pump.
final class DriveSync {
    private let lock = NSLock()
    private var waiting: [String: String]
    private var reads: [String: DriveNamespaceRead] = [:]
    private let push: [String: [DrivePush]]
    private var done = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(requests: [String: String], push: [String: [DrivePush]]) {
        waiting = requests
        self.push = push
        for namespace in requests.values { reads[namespace] = DriveNamespaceRead() }
    }

    /// Record a reply; returns round 2 when one is due.
    func take(_ reply: DriveSyncReply) -> [UInt8]? {
        lock.lock()
        guard let namespace = waiting[reply.requestId] else { lock.unlock(); return nil }
        var round2: [UInt8]?
        if reply.round == 1 {
            reads[namespace]?.answered = true
            reads[namespace]?.objects += reply.objects
            reads[namespace]?.versions = reply.versions
            // Round 2 echoes their versions back. Stopping at round 1 leaves the sync open on their side.
            round2 = RlDrive.buildSync(
                namespace: namespace, requestId: reply.requestId, round: 2, known: reply.versions,
                types: reply.versions.typeNames + [RlDrive.typeKv], push: push[namespace] ?? []
            )
        } else if reply.terminated, !reply.versions.isEmpty {
            reads[namespace]?.versions = reply.versions
        }
        var resume: CheckedContinuation<Void, Never>?
        if reply.terminated {
            reads[namespace]?.finished = true
            waiting[reply.requestId] = nil
            if waiting.isEmpty {
                done = true
                resume = continuation
                continuation = nil
            }
        }
        lock.unlock()
        resume?.resume()
        return round2
    }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if done || Task.isCancelled {
                    lock.unlock()
                    c.resume()
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    var result: [String: DriveNamespaceRead] {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
}

/// One RLDrive sync at a time per process: the svc33 responder is one slot on the session.
let driveGate = AsyncLock()

extension GlassesSession {
    /// Sync every namespace in `namespaces` on svc33: a full read (nothing declared), with `push` objects handed over
    /// in round 2. Returns what each namespace gave; the caller holds `driveGate`.
    func driveSync(_ namespaces: [String], push: [String: [DrivePush]] = [:], timeout: TimeInterval) async throws -> [String: DriveNamespaceRead] {
        let requests = Dictionary(uniqueKeysWithValues: namespaces.map { (UUID().uuidString.lowercased(), $0) })
        let sync = DriveSync(requests: requests, push: push)
        let assembler = RlDriveAssembler()
        addResponder(RlDrive.serviceId) { message, mux in
            guard message.info.messageType == RlDrive.syncMessage, let whole = assembler.assemble(message.payload) else { return }
            guard let round2 = sync.take(RlDrive.decodeSync(whole)) else { return }
            for piece in RlDrive.chunks(round2) {
                try await mux.sendOnService(RlDrive.serviceId, messageType: RlDrive.syncMessage, payload: piece)
            }
        }
        defer { removeResponder(RlDrive.serviceId) }
        for (id, namespace) in requests.sorted(by: { $0.value < $1.value }) {
            try await send(service: RlDrive.serviceId, type: RlDrive.syncMessage, payload: RlDrive.buildSync(namespace: namespace, requestId: id, round: 0))
        }
        _ = try await withDeadline(timeout) { await sync.wait() }
        return sync.result
    }
}
