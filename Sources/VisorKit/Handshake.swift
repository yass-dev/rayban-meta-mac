import Foundation

/// Link setup message types, service 5.
public enum LinkSetupMsgType: Int {
    case requestEncryption = 1
    case enableEncryption = 2
    case endLinkSetup = 0x1000
}

/// First handshake message: the initiator proposes ECDH parameters.
public struct RequestEncryption {
    public var publicKey: [UInt8]
    public var challenge: [UInt8]
    public var ellipticCurve = 0
    public var supportedParameters = 31
    public var keyHints: [[UInt8]] = []
    public var quirks = 0
    public var airshieldVersion = 16

    public init(publicKey: [UInt8], challenge: [UInt8]) {
        self.publicKey = publicKey
        self.challenge = challenge
    }

    public func encode() -> [UInt8] {
        var out = Wire.fieldBytes(1, publicKey)
        out += Wire.fieldBytes(2, challenge)
        out += Wire.fieldVarint(3, UInt64(ellipticCurve))
        out += Wire.fieldVarint(4, UInt64(supportedParameters))
        for hint in keyHints { out += Wire.fieldBytes(5, hint) }
        if quirks != 0 { out += Wire.fieldVarint(6, UInt64(quirks)) }
        out += Wire.fieldVarint(7, UInt64(airshieldVersion))
        return out
    }

    public static func decode(_ data: [UInt8]) throws -> RequestEncryption {
        let f = try Wire.parse(data)
        var m = RequestEncryption(publicKey: f.bytes(1), challenge: f.bytes(2))
        m.ellipticCurve = Int(f.varint(3))
        m.supportedParameters = Int(f.varint(4))
        m.keyHints = f.repeatedBytes(5)
        m.quirks = Int(f.varint(6))
        m.airshieldVersion = Int(f.varint(7))
        return m
    }
}

/// Second handshake message: the responder accepts and provides the seed and IV.
public struct EnableEncryption {
    public var publicKey: [UInt8]
    public var seed: [UInt8]
    public var iv: [UInt8]
    /// The sender's preamble sequence counter, unsigned 32 bit.
    public var base: UInt32
    public var parameters = 31
    public var quirks: UInt64 = 0
    public var phasedLinkSetupSupported: UInt64 = 0
    public var supportedLinkSetupServices: UInt64 = 0
    public var linkSwitchVersionSupported: UInt64 = 0

    public init(publicKey: [UInt8], seed: [UInt8], iv: [UInt8], base: UInt32) {
        self.publicKey = publicKey
        self.seed = seed
        self.iv = iv
        self.base = base
    }

    public func encode() -> [UInt8] {
        var out = Wire.fieldBytes(1, publicKey)
        out += Wire.fieldBytes(2, seed)
        out += Wire.fieldBytes(3, iv)
        out += Wire.fieldVarint(4, UInt64(base))
        out += Wire.fieldVarint(5, UInt64(parameters))
        if quirks != 0 { out += Wire.fieldVarint(6, quirks) }
        if phasedLinkSetupSupported != 0 { out += Wire.fieldVarint(7, phasedLinkSetupSupported) }
        if supportedLinkSetupServices != 0 { out += Wire.fieldVarint(8, supportedLinkSetupServices) }
        if linkSwitchVersionSupported != 0 { out += Wire.fieldVarint(9, linkSwitchVersionSupported) }
        return out
    }

    public static func decode(_ data: [UInt8]) throws -> EnableEncryption {
        let f = try Wire.parse(data)
        var m = EnableEncryption(publicKey: f.bytes(1), seed: f.bytes(2), iv: f.bytes(3), base: UInt32(truncatingIfNeeded: f.varint(4)))
        m.parameters = Int(f.varint(5))
        m.quirks = f.varint(6)
        m.phasedLinkSetupSupported = f.varint(7)
        m.supportedLinkSetupServices = f.varint(8)
        m.linkSwitchVersionSupported = f.varint(9)
        return m
    }
}

/// The channel binding: a 32-byte digest of the handshake values that the svc36 trust signs.
public struct HandshakeBinding {
    public let myChallenge: [UInt8]
    public let glChallenge: [UInt8]
    public let mySeed: [UInt8]
    public let glSeed: [UInt8]
    public let myPub: [UInt8]
    /// The glasses' EnableEncryption public key.
    public let glPub: [UInt8]
    /// The glasses' RequestEncryption public key.
    public let glReqPub: [UInt8]

    /// `SHA256(glasses challenge ‖ glasses RequestEncryption key) ‖ SHA256(our seed ‖ our public key)`.
    /// Its SHA-256 is the binding. ECDSA over this preimage with SHA-256 equals NONEwithECDSA over the binding.
    public var primaryPreimage: [UInt8] {
        Hash.sha256(glChallenge, glReqPub) + Hash.sha256(mySeed, myPub)
    }

    public var primary: [UInt8] { Hash.sha256(primaryPreimage) }
}
