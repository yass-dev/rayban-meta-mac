import Foundation

public struct HandshakeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// What the mux needs from the link below it: plaintext in, plaintext out.
public protocol PlaintextLink: AnyObject {
    func send(_ plaintext: [UInt8]) async throws
    func receive() async throws -> [UInt8]
}

/// SecureLink: the AirShield handshake plus the per-direction frame cipher. Port of Visor's `SecureLink.kt`.
public final class SecureLink: PlaintextLink {
    private let transport: Transport
    private var txCrypto: FrameCrypto?
    private var rxCrypto: FrameCrypto?
    /// DATA frames that arrived during the handshake, handled after `open` returns.
    private var pending: [[UInt8]] = []
    /// Channel binding material. Nil until `open` succeeds.
    public private(set) var binding: HandshakeBinding?
    /// The code of the last skipped COMMAND frame.
    public private(set) var lastCommand: Int?
    public var log: ((String) -> Void)?

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Run the AirShield handshake and install the per-direction frame ciphers. EndLinkSetup is NOT sent here.
    public func open() async throws {
        let keyPair = Ecdh.generateEphemeral()
        let myPublic = Ecdh.raw(keyPair)
        let myChallenge = Random.bytes(16)
        let mySeed = Random.bytes(32)
        let myIv = Random.bytes(16)
        let seqBytes = Random.bytes(4)
        let mySeq = UInt32(seqBytes[0]) | (UInt32(seqBytes[1]) << 8) | (UInt32(seqBytes[2]) << 16) | (UInt32(seqBytes[3]) << 24)

        try await sendLinkSetup(
            channel: DataX.linkSetupChannel,
            type: .requestEncryption,
            protobuf: RequestEncryption(publicKey: myPublic, challenge: myChallenge).encode()
        )
        try await sendLinkSetup(
            channel: DataX.enableChannel,
            type: .enableEncryption,
            protobuf: EnableEncryption(publicKey: myPublic, seed: mySeed, iv: myIv, base: mySeq).encode()
        )

        var peerRequest: RequestEncryption?
        var peerEnable: EnableEncryption?
        for _ in 0 ..< 8 {
            let sdu = try await transport.receive()
            if let first = sdu.first, Int(first) & Framing.typeMask == FrameType.data.rawValue {
                pending.append(sdu)
                continue
            }
            let info = try DataX.parseHeader(sdu)
            let payload = Array(sdu[min(info.headerLen, sdu.count)...])
            switch info.messageType {
            case LinkSetupMsgType.requestEncryption.rawValue:
                peerRequest = try RequestEncryption.decode(payload)
            case LinkSetupMsgType.enableEncryption.rawValue:
                peerEnable = try EnableEncryption.decode(payload)
            default:
                log?("handshake: unexpected link setup message type \(info.messageType)")
            }
            if peerRequest != nil, peerEnable != nil { break }
        }
        guard let request = peerRequest, let enable = peerEnable else {
            throw HandshakeError("handshake: missing RequestEncryption / EnableEncryption from the glasses")
        }
        guard enable.publicKey.count == 64, enable.iv.count == 16, request.challenge.count == 16 else {
            throw HandshakeError("handshake: the glasses' key, IV or challenge has the wrong length")
        }

        let secret = try Ecdh.sharedSecret(keyPair, peerPublic64: enable.publicKey)
        binding = HandshakeBinding(
            myChallenge: myChallenge, glChallenge: request.challenge,
            mySeed: mySeed, glSeed: enable.seed,
            myPub: myPublic, glPub: enable.publicKey, glReqPub: request.publicKey
        )
        // RX: our challenge is the nonce, their seed and IV. TX: their challenge, our seed and IV.
        let rxKeys = Kdf.deriveDirectionKeys(secret: secret, nonce: myChallenge, seed: enable.seed, iv: enable.iv)
        let txKeys = Kdf.deriveDirectionKeys(secret: secret, nonce: request.challenge, seed: mySeed, iv: myIv)
        rxCrypto = FrameCrypto(keys: rxKeys, initRxSeq: enable.base)
        txCrypto = FrameCrypto(keys: txKeys, initTxSeq: mySeq)
    }

    /// Send EndLinkSetup as a sealed DATA frame, after trust.
    public func finishLinkSetup(asMain: Int = 1) async throws {
        guard txCrypto != nil else { throw HandshakeError("link not open") }
        let body = Wire.fieldVarint(1, UInt64(asMain)) + Wire.fieldBytes(2, LinkUuid.random()) + Wire.fieldBytes(3, LinkUuid.random())
        let sdu = DataX.buildHeader(channelId: DataX.linkSetupChannel, dataLen: body.count, messageType: LinkSetupMsgType.endLinkSetup.rawValue) + body
        try await send(sdu)
    }

    public func send(_ plaintext: [UInt8]) async throws {
        guard let crypto = txCrypto else { throw HandshakeError("link not open") }
        let frame = Framing.pack(.data, body: try crypto.seal(plaintext))
        try await transport.send(frame)
    }

    /// The next DATA frame's plaintext, pad still on.
    public func receive() async throws -> [UInt8] {
        guard let crypto = rxCrypto else { throw HandshakeError("link not open") }
        while true {
            let sdu: [UInt8]
            if !pending.isEmpty { sdu = pending.removeFirst() } else { sdu = try await transport.receive() }
            let frame = try Framing.unpack(sdu)
            if frame.type == FrameType.data.rawValue {
                return try crypto.unseal(frame.body)
            }
            lastCommand = frame.body.first.map(Int.init)
            log?("skipped a COMMAND frame, code \(lastCommand ?? -1)")
        }
    }

    private func sendLinkSetup(channel: Int, type: LinkSetupMsgType, protobuf: [UInt8]) async throws {
        let serviceId: Int? = type == .requestEncryption ? 5 : nil
        let sdu = DataX.buildHeader(channelId: channel, dataLen: protobuf.count, serviceId: serviceId, messageType: type.rawValue) + protobuf
        try await transport.send(sdu)
    }
}
