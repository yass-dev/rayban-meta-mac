import CryptoKit
import Foundation

/// svc36 message types.
public enum IdentityMsgType: Int {
    case enableTrust = 0x1000
    case enableTrustEc = 0x1001
    case skipChallenge = 0x2000
    case skipChallengeAck = 0x2001
    case startChangeOwnerReq = 0x2002
    case startChangeOwnerResp = 0x2003
    case finishChangeOwnerReq = 0x2004
    case finishChangeOwnerResp = 0x2005
    case identityRequest = 0x3000
    case identityResponse = 0x3001
}

/// svc36 channel status codes.
public enum IdentityStatus: Int {
    case success = 0x1000, failure = 0x1001, notSupported = 0x1002, unavailable = 0x1003
    case keyNotFound = 0x1010
    case invalidReceipt = 0x1040, invalidNonce = 0x1041, invalidUserId = 0x1042
    case invalidAppIdentity = 0x1043, invalidSignature = 0x1044, invalidTime = 0x1045

    public static func name(_ code: Int) -> String {
        if let s = IdentityStatus(rawValue: code) { return "\(s)" }
        return String(format: "0x%04x", code)
    }
}

public enum ServiceIds {
    public static let linkSetup = 5
    public static let atcLinkManager = 10
    public static let media = 18
    public static let airship = 20
    public static let status = 28
    public static let identity = 36
    public static let peerBuildInfo = 100
}

/// The EC P-256 owner key the glasses know the client by.
public struct OwnerKey {
    public let key: P256.Signing.PrivateKey

    public init() { key = P256.Signing.PrivateKey() }
    public init(pem: String) throws { key = try P256.Signing.PrivateKey(pemRepresentation: pem) }

    public var pem: String { key.pemRepresentation }
    /// The public key as 64 raw bytes, x concatenated with y.
    public var publicKey64: [UInt8] { Array(key.publicKey.rawRepresentation) }
    /// How the glasses look the owner up: the SHA-256 of the 64-byte public key.
    public var keyHash: [UInt8] { Hash.sha256(publicKey64) }

    /// Field 3 of EnableTrust: provisioning capabilities.
    static let provisioningCapabilities: UInt64 = 2

    /// ENABLE_TRUST, type 0x1000: the key hash, the raw low-s signature of the binding, the capabilities.
    public func enableTrustBody(binding: HandshakeBinding) throws -> [UInt8] {
        // CryptoKit hashes the data with SHA-256 before signing, so signing the preimage equals
        // NONEwithECDSA over the 32-byte binding digest.
        let signature = try key.signature(for: binding.primaryPreimage)
        let raw = Array(signature.rawRepresentation)
        precondition(raw.count == 64)
        let r = Array(raw[0 ..< 32])
        let s = LowS.normalize(Array(raw[32 ..< 64]))
        return Wire.fieldBytes(1, keyHash) + Wire.fieldBytes(2, r + s) + Wire.fieldVarint(3, OwnerKey.provisioningCapabilities)
    }
}

/// Make `s` low: when it is above half the group order `n`, replace it with `n - s`.
enum LowS {
    static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]
    static let halfOrder: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42, 0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
    ]

    static func greater(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0 ..< 32 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    static func normalize(_ s: [UInt8]) -> [UInt8] {
        guard greater(s, halfOrder) else { return s }
        var out = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            var d = Int(order[i]) - Int(s[i]) - borrow
            if d < 0 { d += 256; borrow = 1 } else { borrow = 0 }
            out[i] = UInt8(d)
        }
        return out
    }
}

/// Which direction of the svc36 trust exchange succeeded.
public struct TrustResult {
    public let txOk: Bool
    public let rxOk: Bool
    /// The status the glasses answered our credential with, when it was not SUCCESS.
    public let refusal: Int?
    public var complete: Bool { txOk && rxOk }
}

/// The svc36 exchange the session runs between the handshake and EndLinkSetup. Port of `Trust.kt`.
public enum TrustExchange {
    public static func run(connection: DataXConnection, binding: HandshakeBinding, key: OwnerKey, timeout: TimeInterval = 5) async throws -> TrustResult {
        let ourChannel = connection.openChannel(ServiceIds.identity)
        try await connection.send(channel: ourChannel, payload: try key.enableTrustBody(binding: binding), messageType: IdentityMsgType.enableTrust.rawValue, serviceId: ServiceIds.identity)
        let ourStatusChannel = DataX.mirror(ourChannel)
        var txOk = false, rxOk = false
        var refusal: Int?
        var deferred: [DataXMessage] = []
        let deadline = Date().addingTimeInterval(timeout)
        while !(txOk && rxOk) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            guard let message = try await withDeadline(remaining, { try await connection.receive() }) else { break }
            let info = message.info
            if info.hasError, info.channelId == ourStatusChannel {
                if info.errorId == IdentityStatus.success.rawValue { txOk = true } else { refusal = info.errorId }
            } else if info.channelId & DataX.originatorBit != 0, info.serviceId == ServiceIds.identity,
                      info.messageType == IdentityMsgType.enableTrust.rawValue || info.messageType == IdentityMsgType.enableTrustEc.rawValue {
                try await connection.sendStatus(channel: DataX.mirror(info.channelId), errorId: IdentityStatus.success.rawValue)
                rxOk = true
            } else {
                deferred.append(message)
            }
        }
        connection.pushback(deferred)
        return TrustResult(txOk: txOk, rxOk: rxOk, refusal: refusal)
    }
}

/// Run `body` with a bound on how long it may wait. Nil when the deadline passed first.
public func withDeadline<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
