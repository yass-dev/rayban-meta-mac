import Foundation

public struct SessionError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Runs for every message of one service, before the message is published.
public typealias Responder = (DataXMessage, DataXConnection) async throws -> Void

/// The one object that owns the link: transport, handshake, trust, EndLinkSetup, and the pump that
/// reads everything after. A simplified port of Visor's `GlassesSession.kt`.
public final class GlassesSession {
    public let transport: Transport
    private let ownerKey: OwnerKey?
    private var link: SecureLink?
    public private(set) var connection: DataXConnection?
    public private(set) var trustResult: TrustResult?
    private var responders: [Int: Responder] = [:]
    private var waiters: [Waiter] = []
    private var pumpTask: Task<Void, Never>?
    private var closed = false
    public var log: ((String) -> Void)?
    public var trace: ((String) -> Void)?
    /// Every service message no responder or waiter took, for whoever wants to look.
    public var onUnhandled: ((DataXMessage, Int) -> Void)?
    /// The pump stopped: the link is gone.
    public var onLost: ((Error) -> Void)?

    /// Someone waiting for one message. The pump may deliver before the waiter suspends, so the
    /// message is kept until it is collected.
    private final class Waiter {
        let match: (DataXMessage, Int) -> Bool
        private let lock = NSLock()
        private var result: Result<DataXMessage, Error>?
        private var continuation: CheckedContinuation<DataXMessage, Error>?

        init(match: @escaping (DataXMessage, Int) -> Bool) { self.match = match }

        func deliver(_ r: Result<DataXMessage, Error>) {
            lock.lock()
            if let c = continuation {
                continuation = nil
                lock.unlock()
                c.resume(with: r)
            } else {
                if result == nil { result = r }
                lock.unlock()
            }
        }

        func wait() async throws -> DataXMessage {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    lock.lock()
                    if let r = result {
                        lock.unlock()
                        c.resume(with: r)
                    } else if Task.isCancelled {
                        lock.unlock()
                        c.resume(throwing: CancellationError())
                    } else {
                        continuation = c
                        lock.unlock()
                    }
                }
            } onCancel: {
                deliver(.failure(CancellationError()))
            }
        }
    }

    private let waitersLock = NSLock()

    private func addWaiter(_ w: Waiter) {
        waitersLock.lock(); defer { waitersLock.unlock() }
        waiters.append(w)
    }

    private func removeWaiter(_ w: Waiter) {
        waitersLock.lock(); defer { waitersLock.unlock() }
        waiters.removeAll { $0 === w }
    }

    private func takeWaiter(for message: DataXMessage, service: Int) -> Waiter? {
        waitersLock.lock(); defer { waitersLock.unlock() }
        guard let i = waiters.firstIndex(where: { $0.match(message, service) }) else { return nil }
        return waiters.remove(at: i)
    }

    public init(transport: Transport, ownerKey: OwnerKey?) {
        self.transport = transport
        self.ownerKey = ownerKey
    }

    public func addResponder(_ serviceId: Int, _ responder: @escaping Responder) {
        responders[serviceId] = responder
    }

    public func removeResponder(_ serviceId: Int) {
        responders[serviceId] = nil
    }

    /// Connect, handshake, trust (when there is an owner key), EndLinkSetup both ways. Then start the pump.
    private func connectTransport() async throws {
        guard try await withDeadline(240, { try await self.transport.connect() }) != nil else {
            transport.close()
            throw SessionError("the glasses did not open the link in 240 s")
        }
    }

    public func open(linkSetupTimeout: TimeInterval = 10) async throws {
        try await connectTransport()
        let link = SecureLink(transport: transport)
        link.log = log
        self.link = link
        guard try await withDeadline(linkSetupTimeout, { try await link.open() }) != nil else {
            transport.close()
            throw SessionError("the glasses stopped answering during link setup")
        }
        let mux = DataXConnection(link: link)
        mux.trace = trace
        connection = mux
        if let ownerKey {
            let result = try await TrustExchange.run(connection: mux, binding: link.binding!, key: ownerKey)
            trustResult = result
            if !result.complete {
                var faults: [String] = []
                if !result.txOk { faults.append("the glasses did not accept our credential" + (result.refusal.map { " (status \(IdentityStatus.name($0)))" } ?? "")) }
                if !result.rxOk { faults.append("the glasses sent no credential of their own") }
                log?("trust incomplete: " + faults.joined(separator: " and "))
            }
        }
        try await link.finishLinkSetup()
        guard try await withDeadline(5, { try await self.answerTheirEndLinkSetup(mux) }) != nil else {
            transport.close()
            throw SessionError("the glasses did not send their EndLinkSetup")
        }
        startPump()
    }

    /// Handshake only, no trust and no EndLinkSetup: what provisioning and the identity probe run on.
    public func openBare(linkSetupTimeout: TimeInterval = 10) async throws {
        try await connectTransport()
        let link = SecureLink(transport: transport)
        link.log = log
        self.link = link
        guard try await withDeadline(linkSetupTimeout, { try await link.open() }) != nil else {
            transport.close()
            throw SessionError("the glasses stopped answering during link setup")
        }
        let mux = DataXConnection(link: link)
        mux.trace = trace
        connection = mux
    }

    private func answerTheirEndLinkSetup(_ mux: DataXConnection) async throws {
        var deferred: [DataXMessage] = []
        while true {
            let message = try await mux.receive()
            if message.info.channelId == DataX.linkSetupChannel, message.info.messageType == LinkSetupMsgType.endLinkSetup.rawValue {
                try await mux.sendStatus(channel: DataX.mirror(message.info.channelId), errorId: DataX.success)
                mux.pushback(deferred)
                return
            }
            deferred.append(message)
        }
    }

    private func startPump() {
        pumpTask = Task { [weak self] in
            guard let self, let mux = self.connection else { return }
            do {
                while !Task.isCancelled {
                    let message = try await mux.receive()
                    await self.handle(message, mux)
                }
            } catch {
                if !self.closed {
                    self.log?("link lost: \(error)")
                    self.failWaiters(error)
                    self.onLost?(error)
                }
            }
        }
    }

    private func handle(_ message: DataXMessage, _ mux: DataXConnection) async {
        let info = message.info
        if info.serviceId != 0 { mux.registry.bindInbound(info.channelId, serviceId: info.serviceId) }
        let serviceId = mux.registry.serviceForInbound(info.channelId)

        if (serviceId == 30 || serviceId == 79), info.channelId & DataX.originatorBit != 0, !info.hasError {
            try? await mux.sendStatus(channel: DataX.mirror(info.channelId), errorId: DataX.serviceNotFound)
        }
        // The glasses push their own svc36 credential again after a change of owner: acknowledge it.
        if serviceId == ServiceIds.identity, info.channelId & DataX.originatorBit != 0, !info.hasError,
           info.messageType == IdentityMsgType.enableTrust.rawValue || info.messageType == IdentityMsgType.enableTrustEc.rawValue {
            try? await mux.sendStatus(channel: DataX.mirror(info.channelId), errorId: IdentityStatus.success.rawValue)
        }

        if let responder = responders[serviceId], !info.hasError {
            do { try await responder(message, mux) } catch { log?("responder for service \(serviceId) failed: \(error)") }
        }

        if let waiter = takeWaiter(for: message, service: serviceId) {
            waiter.deliver(.success(message))
            return
        }

        if info.hasError {
            if info.errorId != DataX.success {
                log?(String(format: "service %d answered status 0x%04x on channel 0x%04x", serviceId, info.errorId, info.channelId))
            }
            return
        }
        if info.isClosed, message.payload.isEmpty { return }
        onUnhandled?(message, serviceId)
    }

    private func failWaiters(_ error: Error) {
        waitersLock.lock()
        let pending = waiters
        waiters = []
        waitersLock.unlock()
        for w in pending { w.deliver(.failure(error)) }
    }

    /// Send on the session's channel for `service`.
    public func send(service: Int, type: Int, payload: [UInt8] = []) async throws {
        guard let mux = connection else { throw SessionError("not connected") }
        try await mux.sendOnService(service, messageType: type, payload: payload)
    }

    /// Register interest in the next message that matches, BEFORE sending what provokes it.
    private func expect(_ match: @escaping (DataXMessage, Int) -> Bool) -> Waiter {
        let w = Waiter(match: match)
        addWaiter(w)
        return w
    }

    private func collect(_ w: Waiter, timeout: TimeInterval) async throws -> DataXMessage {
        guard pumpTask != nil else { removeWaiter(w); throw SessionError("the pump is not running") }
        guard let result = try await withDeadline(timeout, { try await w.wait() }) else {
            removeWaiter(w)
            throw SessionError("timed out waiting for the glasses")
        }
        return result
    }

    /// The next message that matches, with a bound on the wait. The pump must be running.
    public func await(timeout: TimeInterval, _ match: @escaping (DataXMessage, Int) -> Bool) async throws -> DataXMessage {
        try await collect(expect(match), timeout: timeout)
    }

    /// Ask, then wait for the first message on `service` of one of `types`.
    public func request(service: Int, type: Int, payload: [UInt8] = [], expect types: Set<Int>, timeout: TimeInterval = 10) async throws -> DataXMessage {
        let w = expect { message, svc in svc == service && types.contains(message.info.messageType) }
        do { try await send(service: service, type: type, payload: payload) } catch { removeWaiter(w); throw error }
        return try await collect(w, timeout: timeout)
    }

    public func close() {
        closed = true
        pumpTask?.cancel()
        transport.close()
        failWaiters(SessionError("closed"))
    }
}

/// svc100 peer build info: the phone announces itself and the glasses answer with their build.
public struct DeviceInfo: CustomStringConvertible {
    public let build: String
    public let serial: String
    public let deviceUuid: String
    public let bluetoothAddress: String
    public let model: String

    public var description: String {
        "model \(model), serial \(serial), build \(build), bt \(bluetoothAddress)"
    }

    public static func decode(_ payload: [UInt8]) -> DeviceInfo {
        let f = Wire.parseLenient(payload)
        return DeviceInfo(build: f.string(1), serial: f.string(2), deviceUuid: f.string(4), bluetoothAddress: f.string(6), model: f.string(8))
    }
}

extension GlassesSession {
    /// Announce on svc100 and read the glasses' build info back. Needs the owner key: a scoped link.
    public func peerDeviceInfo(timeout: TimeInterval = 10) async throws -> DeviceInfo {
        let answer = try await request(service: ServiceIds.peerBuildInfo, type: 1, expect: [3], timeout: timeout)
        return DeviceInfo.decode(answer.payload)
    }
}
