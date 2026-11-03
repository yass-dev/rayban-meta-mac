import CommonCrypto
import CryptoKit
import Foundation

public struct AuthenticationError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum Hash {
    public static func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    public static func hmacSha256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Constant-time comparison.
    public static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// One direction's key set: AES-256, HMAC-SHA256, and the initial CBC IV.
public struct SessionKeys {
    public let aesKey: [UInt8]
    public let hmacKey: [UInt8]
    public let iv: [UInt8]
}

/// AirShield key schedule. Port of Visor's `Kdf.kt`.
public enum Kdf {
    static let airShieldInfo = Array("AirShield".utf8)
    static let hmacDeriveLabel = Array("hmac_derive".utf8)

    public static func deriveDirectionKeys(secret: [UInt8], nonce: [UInt8], seed: [UInt8], iv: [UInt8]) -> SessionKeys {
        precondition(secret.count == 32 && iv.count == 16)
        let aesSalt = Hash.sha256(nonce, seed)
        let hmacSalt = Hash.sha256(seed, nonce, hmacDeriveLabel)
        let aesKey = hkdfExpand(prk: Hash.hmacSha256(key: aesSalt, data: secret), info: airShieldInfo, length: 32)
        let hmacKey = hkdfExpand(prk: Hash.hmacSha256(key: hmacSalt, data: secret), info: airShieldInfo, length: 32)
        return SessionKeys(aesKey: aesKey, hmacKey: hmacKey, iv: iv)
    }

    static func hkdfExpand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        var out: [UInt8] = []
        var t: [UInt8] = []
        var counter: UInt8 = 1
        while out.count < length {
            t = Hash.hmacSha256(key: prk, data: t + info + [counter])
            out += t
            counter &+= 1
        }
        return Array(out.prefix(length))
    }
}

public enum AesCbc {
    /// AES-256-CBC with no padding, on whole blocks.
    public static func run(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) throws -> [UInt8] {
        precondition(key.count == 32 && iv.count == 16 && data.count % 16 == 0)
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            key, key.count,
            iv,
            data, data.count,
            &out, out.count,
            &moved
        )
        guard status == kCCSuccess, moved == data.count else {
            throw AuthenticationError("AES-CBC failed with status \(status)")
        }
        return out
    }
}

/// AirShield per-frame cipher: AES-256-CBC plus HMAC-SHA256, encrypt-then-MAC. Port of `Cipher.kt`.
public final class FrameCrypto {
    public static let tagSize = 8
    public static let block = 16
    public static let padOffset = 0xC0
    static let counterPrefix: [UInt8] = [0x02, 0x02, 0x00, 0x00]

    private let aesKey: [UInt8]
    private let hmacKey: [UInt8]
    private var txIv: [UInt8]
    private var rxIv: [UInt8]
    private var txSeq: UInt32
    private var rxSeq: UInt32

    public init(keys: SessionKeys, initTxSeq: UInt32 = 0, initRxSeq: UInt32 = 0) {
        aesKey = keys.aesKey
        hmacKey = keys.hmacKey
        txIv = keys.iv
        rxIv = keys.iv
        txSeq = initTxSeq
        rxSeq = initRxSeq
    }

    /// Modified PKCS#7: the pad byte is `pad_len + 0xC0`, and an aligned input gets a whole block.
    public static func pad(_ data: [UInt8]) -> [UInt8] {
        let padLen = block - (data.count % block)
        return data + [UInt8](repeating: UInt8((padLen + padOffset) & 0xFF), count: padLen)
    }

    /// A frame's plaintext without its modified PKCS#7 tail, when the tail fits the rule.
    public static func withoutPad(_ plaintext: [UInt8]) -> [UInt8] {
        guard let last = plaintext.last else { return plaintext }
        let padLen = (Int(last) + 0x40) & 0xFF
        if padLen >= 1, padLen <= 16, plaintext.count >= padLen,
           plaintext.suffix(padLen).allSatisfy({ $0 == last }) {
            return Array(plaintext.dropLast(padLen))
        }
        return plaintext
    }

    private func mac(seq: UInt32, blockCount: Int, ciphertext: [UInt8]) -> [UInt8] {
        var input = FrameCrypto.counterPrefix
        input += [UInt8(seq & 0xFF), UInt8((seq >> 8) & 0xFF), UInt8((seq >> 16) & 0xFF), UInt8((seq >> 24) & 0xFF)]
        input.append(UInt8(blockCount))
        input += ciphertext
        return Array(Hash.hmacSha256(key: hmacKey, data: input).prefix(FrameCrypto.tagSize))
    }

    /// The DATA frame body for one plaintext: tag, block count, ciphertext. Advances the send state.
    public func seal(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ciphertext = try AesCbc.run(key: aesKey, iv: txIv, data: FrameCrypto.pad(plaintext), encrypt: true)
        let blockCount = ciphertext.count / FrameCrypto.block - 1
        guard blockCount <= 0xFF else { throw AuthenticationError("plaintext too large for a single AirShield frame") }
        let tag = mac(seq: txSeq, blockCount: blockCount, ciphertext: ciphertext)
        txIv = Array(ciphertext.suffix(FrameCrypto.block))
        txSeq &+= 1
        return tag + [UInt8(blockCount)] + ciphertext
    }

    /// Verify and decrypt one DATA frame body. The pad is left on: the DataX layer trims by header length.
    public func unseal(_ frame: [UInt8]) throws -> [UInt8] {
        guard frame.count >= FrameCrypto.tagSize + 1 + FrameCrypto.block else {
            throw AuthenticationError("frame too short")
        }
        let tag = Array(frame[0 ..< FrameCrypto.tagSize])
        let blockCount = Int(frame[FrameCrypto.tagSize])
        let ciphertext = Array(frame[(FrameCrypto.tagSize + 1)...])
        guard ciphertext.count == (blockCount + 1) * FrameCrypto.block else {
            throw AuthenticationError("ciphertext length != block_count")
        }
        guard Hash.equal(tag, mac(seq: rxSeq, blockCount: blockCount, ciphertext: ciphertext)) else {
            throw AuthenticationError("MAC verification failed")
        }
        let plaintext = try AesCbc.run(key: aesKey, iv: rxIv, data: ciphertext, encrypt: false)
        rxIv = Array(ciphertext.suffix(FrameCrypto.block))
        rxSeq &+= 1
        return plaintext
    }
}

/// ECDH on secp256r1, with the 64-byte `x ‖ y` wire form.
public enum Ecdh {
    public typealias PrivateKey = P256.KeyAgreement.PrivateKey

    public static func generateEphemeral() -> PrivateKey { PrivateKey() }

    public static func raw(_ key: PrivateKey) -> [UInt8] { Array(key.publicKey.rawRepresentation) }

    /// The 32-byte x coordinate of the shared point.
    public static func sharedSecret(_ key: PrivateKey, peerPublic64: [UInt8]) throws -> [UInt8] {
        guard peerPublic64.count == 64 else {
            throw ProtocolFormatError("peer public key must be 64 bytes, got \(peerPublic64.count)")
        }
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublic64)
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Array($0) }
    }
}

/// The 16-byte UUIDs EndLinkSetup and the Wi-Fi messages carry, and the firmware check they have to pass.
public enum LinkUuid {
    public static func random() -> [UInt8] {
        let u = UUID().uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        precondition(isValid(bytes))
        return bytes
    }

    public static func isValid(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && (bytes[6] & 0xF0) == 0x40 && (bytes[8] & 0xC0) == 0x80
    }

    public static func format(_ raw: [UInt8]) -> String {
        let h = raw.hex
        guard raw.count == 16 else { return h }
        let s = Array(h)
        return String(s[0 ..< 8]) + "-" + String(s[8 ..< 12]) + "-" + String(s[12 ..< 16]) + "-" + String(s[16 ..< 20]) + "-" + String(s[20...])
    }
}

public enum Random {
    public static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        precondition(status == errSecSuccess)
        return out
    }
}
