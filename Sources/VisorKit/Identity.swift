import Foundation

/// IdentityResponse fields 1 and 2: the glasses' certificate and serial.
public struct DeviceIdentity {
    public let certDer: [UInt8]
    public let serial: String

    public static func decode(_ data: [UInt8]) -> DeviceIdentity {
        let f = Wire.parseLenient(data)
        return DeviceIdentity(certDer: f.bytes(1), serial: f.string(2))
    }
}

/// An ownership receipt as carried over svc36: {1: signature, 2: JSON body}.
public struct Receipt {
    public let signature: [UInt8]
    public let bodyJson: [UInt8]

    public func encode() -> [UInt8] { Wire.fieldBytes(1, signature) + Wire.fieldBytes(2, bodyJson) }

    public static func decode(_ data: [UInt8]) -> Receipt {
        let f = Wire.parseLenient(data)
        return Receipt(signature: f.bytes(1), bodyJson: f.bytes(2))
    }

    public var info: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(bodyJson))) as? [String: Any] ?? [:]
    }
}

public struct ProvisioningError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// The svc36 flow on a bare link: identity, skip challenge, and the change of owner. Port of `Provision.kt`.
public final class IdentityFlow {
    private let connection: DataXConnection
    private let channel: Int
    private var first = true
    private let timeout: TimeInterval
    public var log: ((String) -> Void)?

    public init(connection: DataXConnection, timeout: TimeInterval = 20) {
        self.connection = connection
        self.timeout = timeout
        channel = connection.openChannel(ServiceIds.identity)
    }

    private func send(_ type: IdentityMsgType, _ payload: [UInt8] = []) async throws {
        try await connection.send(channel: channel, payload: payload, messageType: type.rawValue, serviceId: first ? ServiceIds.identity : nil)
        first = false
    }

    private func await(_ type: IdentityMsgType) async throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        let mirror = DataX.mirror(channel)
        while deadline.timeIntervalSinceNow > 0 {
            guard let message = try await withDeadline(deadline.timeIntervalSinceNow, { try await self.connection.receive() }) else { break }
            if message.info.messageType == type.rawValue { return message.payload }
            if message.info.hasError, message.info.channelId == mirror {
                if message.info.errorId == IdentityStatus.invalidUserId.rawValue {
                    throw ProvisioningError("these glasses belong to another Meta account (INVALID_USER_ID)")
                }
                throw ProvisioningError("the glasses answered status \(IdentityStatus.name(message.info.errorId)) while awaiting \(type)")
            }
            log?(String(format: "identity flow: skipped svc %d type 0x%04x on channel 0x%04x", message.info.serviceId, message.info.messageType, message.info.channelId))
        }
        throw ProvisioningError("timed out awaiting \(type)")
    }

    /// Who the glasses are: their certificate and serial. Works without being the owner.
    public func identity() async throws -> DeviceIdentity {
        try await send(.identityRequest)
        return DeviceIdentity.decode(try await `await`(.identityResponse))
    }

    /// The device nonce for a pair request.
    public func skipChallenge() async throws -> [UInt8] {
        try await send(.skipChallenge)
        return Wire.parseLenient(try await `await`(.skipChallengeAck)).bytes(1)
    }

    /// The change of owner: the two Meta receipts, installed on the glasses.
    public func changeOwner(backend: PairingBackend, appPubkey: [UInt8], onStep: (String) -> Void) async throws -> Receipt {
        onStep("identity")
        let identity = try await self.identity()
        onStep("skip challenge")
        let nonce = try await skipChallenge()
        onStep("pair_request to Meta")
        let pending = try await backend.pairRequest(certDer: identity.certDer, serial: identity.serial, deviceNonce: nonce, appPubkey: appPubkey)
        onStep("start change owner")
        try await send(.startChangeOwnerReq, pending.encode())
        let devicePending = Receipt.decode(try await `await`(.startChangeOwnerResp))
        onStep("pair to Meta")
        let final = try await backend.pair(devicePending: devicePending)
        onStep("finish change owner")
        try await send(.finishChangeOwnerReq, final.encode())
        _ = try await `await`(.finishChangeOwnerResp)
        return final
    }
}
