import Foundation

/// One decoded DataX message: its header and its application payload.
public struct DataXMessage {
    public let info: MessageInfo
    public let payload: [UInt8]
}

/// Which DataX channel is talking to which service, right now. Port of `ChannelRegistry.kt`.
final class ChannelRegistry {
    private var local: [Int: Int] = [:]
    private var peer: [Int: Int] = [:]
    // The counter starts at 2: channel 0x8001 is the link setup channel.
    private var nextChannel = 2
    private let lock = NSLock()

    func nextLocalChannel() -> Int {
        lock.lock(); defer { lock.unlock() }
        let channel = nextChannel
        nextChannel += 1
        return DataX.originatorBit | channel
    }

    func bindLocal(_ channelId: Int, serviceId: Int) {
        lock.lock(); defer { lock.unlock() }
        local[channelId & 0x7FFF] = serviceId
    }

    func bindInbound(_ channelId: Int, serviceId: Int) {
        lock.lock(); defer { lock.unlock() }
        if channelId & DataX.originatorBit != 0 { peer[channelId & 0x7FFF] = serviceId } else { local[channelId & 0x7FFF] = serviceId }
    }

    func serviceForInbound(_ channelId: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (channelId & DataX.originatorBit != 0 ? peer : local)[channelId & 0x7FFF] ?? 0
    }

    func closeInbound(_ channelId: Int) {
        lock.lock(); defer { lock.unlock() }
        if channelId & DataX.originatorBit != 0 { peer[channelId & 0x7FFF] = nil } else { local[channelId & 0x7FFF] = nil }
    }
}

/// The channel mux riding on one plaintext link. Port of `DataXConnection.kt`, without the reader
/// coroutine: one task reads, and it is the session's pump.
public final class DataXConnection {
    private let link: PlaintextLink
    let registry = ChannelRegistry()
    private var inbox: [DataXMessage] = []
    private var rxLastType: [Int: Int] = [:]
    /// The DataX stream after the last whole message: the start of the next one, cut wherever the frame ended.
    private var carry: [UInt8] = []
    private var serviceChannels: [Int: Int] = [:]
    private let sendLock = AsyncLock()
    public var trace: ((String) -> Void)?

    public init(link: PlaintextLink) {
        self.link = link
    }

    /// Allocate a local channel id for `serviceId` and bind it in the registry.
    public func openChannel(_ serviceId: Int) -> Int {
        let channelId = registry.nextLocalChannel()
        registry.bindLocal(channelId, serviceId: serviceId)
        return channelId
    }

    public func send(channel: Int, payload: [UInt8], messageType: Int? = nil, serviceId: Int? = nil) async throws {
        let header = DataX.buildHeader(channelId: channel, dataLen: payload.count, serviceId: serviceId, messageType: messageType)
        try await sendLock.withLock { try await link.send(header + payload) }
    }

    /// Send on this connection's one channel for `serviceId`, opening it the first time.
    public func sendOnService(_ serviceId: Int, messageType: Int, payload: [UInt8]) async throws {
        if let known = serviceChannels[serviceId] {
            try await send(channel: known, payload: payload, messageType: messageType)
            return
        }
        let channel = openChannel(serviceId)
        serviceChannels[serviceId] = channel
        try await send(channel: channel, payload: payload, messageType: messageType, serviceId: serviceId)
    }

    /// A bare DataX status frame: an error id tag, zero payload.
    public func sendStatus(channel: Int, errorId: Int) async throws {
        try await sendLock.withLock { try await link.send(DataX.buildHeader(channelId: channel, dataLen: 0, errorId: errorId)) }
    }

    /// The next DataX message, decrypting more link frames as needed.
    public func receive() async throws -> DataXMessage {
        while inbox.isEmpty {
            inbox.append(contentsOf: try decode(try await link.receive()))
        }
        let message = inbox.removeFirst()
        if message.info.isClosed { registry.closeInbound(message.info.channelId) }
        return message
    }

    /// Return messages to the front of the inbox, in their original order.
    public func pushback(_ messages: [DataXMessage]) {
        inbox.insert(contentsOf: messages, at: 0)
    }

    public var buffered: Bool { !inbox.isEmpty }

    private func decode(_ plaintext: [UInt8]) throws -> [DataXMessage] {
        let messages = try splitMessages(plaintext).map { DataXMessage(info: applyTypeCache($0.info), payload: $0.payload) }
        if let trace {
            var line = "FRAME \(plaintext.count) bytes"
            for m in messages {
                line += String(format: "\n   msg ch=0x%04x svc=%d mt=0x%04x len=%d payload=%d", m.info.channelId, m.info.serviceId, m.info.messageType, m.info.length, m.payload.count)
            }
            if !carry.isEmpty { line += "\n   CARRY \(carry.count)" }
            trace(line)
        }
        return messages
    }

    private func applyTypeCache(_ info: MessageInfo) -> MessageInfo {
        var info = info
        if info.messageType != 0 {
            rxLastType[info.channelId] = info.messageType
            return info
        }
        if !info.hasError, let cached = rxLastType[info.channelId] { info.messageType = cached }
        return info
    }

    /// Walk the frame into DataX messages by `wireTotal = 4 + length`. The pad comes off first, and a
    /// message cut by the frame's end carries on at the head of the next frame.
    private func splitMessages(_ plaintext: [UInt8]) throws -> [DataXMessage] {
        let stream = carry + FrameCrypto.withoutPad(plaintext)
        var messages: [DataXMessage] = []
        var pos = 0
        while stream.count - pos >= 4 {
            let wireTotal = try DataX.parseHeader(Array(stream[pos ..< pos + 4])).wireTotal
            if stream.count - pos < wireTotal { break }
            let whole = Array(stream[pos ..< pos + wireTotal])
            let info = try DataX.parseHeader(whole)
            messages.append(DataXMessage(info: info, payload: Array(whole[min(info.headerLen, whole.count)...])))
            pos += wireTotal
        }
        carry = Array(stream[pos...])
        return messages
    }
}

/// A mutex for async code: one sender at a time on the link, so the IV chain and the sequence move in step.
public actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
