import Foundation
import Network

public struct TransportError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// A byte pipe under AirShield. Each SDU is one whole message.
public protocol Transport: AnyObject {
    func connect() async throws
    func send(_ sdu: [UInt8]) async throws
    func receive() async throws -> [UInt8]
    func close()
}

/// Bytes arriving from a socket callback, read on the other side by exact count, with cancellation.
/// Appends are synchronous and take a lock, so bytes stay in the order the callbacks delivered them:
/// one reordered chunk breaks the AirShield IV chain and every later frame fails its MAC.
public final class BytePipe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var head = 0
    private var failure: Error?
    private var waiter: (need: Int, continuation: CheckedContinuation<[UInt8], Error>)?

    public init() {}

    public func append(_ bytes: [UInt8]) {
        lock.lock()
        buffer.append(contentsOf: bytes)
        var ready: (CheckedContinuation<[UInt8], Error>, [UInt8])?
        if let w = waiter, let taken = takeLocked(w.need) {
            waiter = nil
            ready = (w.continuation, taken)
        }
        lock.unlock()
        if let (c, taken) = ready { c.resume(returning: taken) }
    }

    public func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.continuation.resume(throwing: error)
    }

    public var available: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count - head
    }

    /// Exactly `n` bytes, waiting for them if needed.
    public func read(_ n: Int) async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
                lock.lock()
                if let taken = takeLocked(n) {
                    lock.unlock()
                    c.resume(returning: taken)
                } else if let failure {
                    lock.unlock()
                    c.resume(throwing: failure)
                } else {
                    precondition(waiter == nil, "one reader at a time")
                    waiter = (n, c)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.continuation.resume(throwing: CancellationError())
        }
    }

    private func takeLocked(_ n: Int) -> [UInt8]? {
        guard buffer.count - head >= n else { return nil }
        let out = Array(buffer[head ..< head + n])
        head += n
        if head > 65536, head * 2 > buffer.count {
            buffer.removeFirst(head)
            head = 0
        }
        return out
    }
}

/// Cuts a byte stream into SDUs by the first bytes' length rule.
public enum SduReader {
    public static func next(from pipe: BytePipe) async throws -> [UInt8] {
        var head = try await pipe.read(Sdu.minHead)
        var total = try Sdu.length(head: head)
        if total == nil {
            head += try await pipe.read(Sdu.airShieldHeader - head.count)
            total = try Sdu.length(head: head)
        }
        guard let total else { throw ProtocolFormatError("could not measure the SDU") }
        return head + (try await pipe.read(total - head.count))
    }
}

/// The glasses' own socket on Wi-Fi. It carries raw SDUs, framed exactly as on RFCOMM.
public final class TcpTransport: Transport {
    private let host: String
    private let port: UInt16
    private let pipe = BytePipe()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "visor.tcp")
    public var log: ((String) -> Void)?

    public init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(port)
    }

    public func connect() async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = conn
        final class Once { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; c.resume() }
                case .failed(let error):
                    if !once.done { once.done = true; c.resume(throwing: TransportError("nothing answered on \(self?.host ?? ""):\(self?.port ?? 0) (\(error))")) }
                    else { self?.pipe.fail(TransportError("TCP failed: \(error)")) }
                case .cancelled:
                    if !once.done { once.done = true; c.resume(throwing: TransportError("TCP cancelled")) }
                    else { self?.pipe.fail(TransportError("TCP closed")) }
                case .waiting(let error):
                    self?.log?("TCP waiting: \(error)")
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        readLoop(conn)
    }

    private func readLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.pipe.append(data.bytes)
            }
            if let error {
                self.pipe.fail(TransportError("TCP read failed: \(error)"))
                return
            }
            if isComplete {
                self.pipe.fail(TransportError("the glasses closed the TCP connection"))
                return
            }
            self.readLoop(conn)
        }
    }

    public func send(_ sdu: [UInt8]) async throws {
        guard let conn = connection else { throw TransportError("not connected") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(sdu), completion: .contentProcessed { error in
                if let error { c.resume(throwing: TransportError("TCP write failed: \(error)")) } else { c.resume() }
            })
        }
    }

    public func receive() async throws -> [UInt8] {
        try await SduReader.next(from: pipe)
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }
}

/// A transport view that logs every SDU it carries.
public final class WireTap: Transport {
    private let inner: Transport
    private let log: (_ outbound: Bool, _ sdu: [UInt8]) -> Void

    public init(_ inner: Transport, log: @escaping (_ outbound: Bool, _ sdu: [UInt8]) -> Void) {
        self.inner = inner
        self.log = log
    }

    public func connect() async throws { try await inner.connect() }
    public func send(_ sdu: [UInt8]) async throws {
        log(true, sdu)
        try await inner.send(sdu)
    }
    public func receive() async throws -> [UInt8] {
        let sdu = try await inner.receive()
        log(false, sdu)
        return sdu
    }
    public func close() { inner.close() }
}
