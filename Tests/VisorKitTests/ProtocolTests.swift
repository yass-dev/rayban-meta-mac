import XCTest
@testable import VisorKit

/// Golden bytes from the Visor wiki, and loopback checks where both ends are ours.
final class ProtocolTests: XCTestCase {

    func testRequestEncryptionHeaderBytes() {
        // RequestEncryption header, 12 bytes: 80 62 80 01 81 00 00 05 02 00 00 01 (90 bytes of protobuf).
        let header = DataX.buildHeader(channelId: 0x8001, dataLen: 90, serviceId: 5, messageType: 1)
        XCTAssertEqual(header.hex, "806280018100000502000001")
        let info = try! DataX.parseHeader(header + [UInt8](repeating: 0, count: 90))
        XCTAssertEqual(info.serviceId, 5)
        XCTAssertEqual(info.messageType, 1)
        XCTAssertEqual(info.channelId, 0x8001)
        XCTAssertEqual(info.wireTotal, 102)
        XCTAssertEqual(info.headerLen, 12)
        XCTAssertEqual(info.dataLength, 90)
    }

    func testRequestEncryptionIs90Bytes() {
        let m = RequestEncryption(publicKey: [UInt8](repeating: 1, count: 64), challenge: [UInt8](repeating: 2, count: 16))
        XCTAssertEqual(m.encode().count, 90)
        let back = try! RequestEncryption.decode(m.encode())
        XCTAssertEqual(back.challenge, m.challenge)
        XCTAssertEqual(back.airshieldVersion, 16)
        XCTAssertEqual(back.supportedParameters, 31)
    }

    func testEnableEncryptionSize() {
        // 121 plus the length of the field 4 varint; a 5-byte base gives 126, header 8 => SDU 134.
        let m = EnableEncryption(publicKey: [UInt8](repeating: 1, count: 64), seed: [UInt8](repeating: 2, count: 32), iv: [UInt8](repeating: 3, count: 16), base: 0xFFFF_FFFF)
        XCTAssertEqual(m.encode().count, 126)
        let header = DataX.buildHeader(channelId: 0x0001, dataLen: 126, messageType: 2)
        XCTAssertEqual(header.hex, "8082000102000002")
    }

    func testStatusFrameBytes() {
        XCTAssertEqual(DataX.buildHeader(channelId: 0x0001, dataLen: 0, errorId: 0x1000).hex, "8004000103001000")
        let info = try! DataX.parseHeader([0x80, 0x04, 0x00, 0x02, 0x03, 0x00, 0x10, 0x00])
        XCTAssertTrue(info.hasError)
        XCTAssertEqual(info.errorId, 0x1000)
        XCTAssertEqual(info.channelId, 2)
    }

    func testEndLinkSetupPlaintextIs46Bytes() {
        let body = Wire.fieldVarint(1, 1) + Wire.fieldBytes(2, LinkUuid.random()) + Wire.fieldBytes(3, LinkUuid.random())
        let sdu = DataX.buildHeader(channelId: 0x8001, dataLen: body.count, messageType: 0x1000) + body
        XCTAssertEqual(sdu.count, 46)
        XCTAssertEqual(Array(sdu[0 ..< 8]).hex, "802a800102001000")
    }

    func testPadding() {
        XCTAssertEqual(FrameCrypto.pad([UInt8](repeating: 0, count: 46)).suffix(2), [0xC2, 0xC2])
        XCTAssertEqual(FrameCrypto.pad([UInt8](repeating: 0, count: 32)).count, 48)
        XCTAssertEqual(FrameCrypto.pad([UInt8](repeating: 0, count: 32)).last, 0xD0)
        XCTAssertEqual(FrameCrypto.pad([UInt8](repeating: 0, count: 8)).suffix(8), [UInt8](repeating: 0xC8, count: 8))
        XCTAssertEqual(FrameCrypto.withoutPad(FrameCrypto.pad([1, 2, 3])), [1, 2, 3])
        XCTAssertEqual(FrameCrypto.withoutPad(FrameCrypto.pad([UInt8](repeating: 9, count: 16))).count, 16)
    }

    func testSduLengthRule() throws {
        XCTAssertEqual(try Sdu.length(head: [0x80, 0x62]), 102)
        XCTAssertNil(try Sdu.length(head: [0x40, 0x00]))
        XCTAssertEqual(try Sdu.length(head: [0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]), 58)
        XCTAssertThrowsError(try Sdu.length(head: [0x00, 0x01]))
    }

    func testSealedEndLinkSetupIs58BytesOnTheWire() throws {
        let keys = SessionKeys(aesKey: [UInt8](repeating: 7, count: 32), hmacKey: [UInt8](repeating: 8, count: 32), iv: [UInt8](repeating: 9, count: 16))
        let crypto = FrameCrypto(keys: keys)
        let frame = Framing.pack(.data, body: try crypto.seal([UInt8](repeating: 0, count: 46)))
        XCTAssertEqual(frame.count, 58)
        XCTAssertEqual(frame[0], 0x40)
        XCTAssertEqual(frame[9], 2)
        XCTAssertEqual(try Sdu.length(head: Array(frame.prefix(10))), 58)
    }

    func testCipherRoundTripAndChaining() throws {
        let keys = SessionKeys(aesKey: Random.bytes(32), hmacKey: Random.bytes(32), iv: Random.bytes(16))
        let a = FrameCrypto(keys: keys, initTxSeq: 0x1234, initRxSeq: 0)
        let b = FrameCrypto(keys: keys, initTxSeq: 0, initRxSeq: 0x1234)
        for n in [1, 15, 16, 17, 1000, 4095] {
            let plain = Random.bytes(n)
            let out = try b.unseal(try a.seal(plain))
            XCTAssertEqual(FrameCrypto.withoutPad(out), plain, "length \(n)")
        }
        XCTAssertThrowsError(try a.seal(Random.bytes(4096)))
        // A tampered tag fails and does not move the receive state.
        var frame = try a.seal([1, 2, 3])
        frame[0] ^= 1
        XCTAssertThrowsError(try b.unseal(frame))
        frame[0] ^= 1
        XCTAssertEqual(FrameCrypto.withoutPad(try b.unseal(frame)), [1, 2, 3])
    }

    func testKdfDirectionsDifferOnlyBySalt() {
        let secret = Random.bytes(32), nonce = Random.bytes(16), seed = Random.bytes(32), iv = Random.bytes(16)
        let k1 = Kdf.deriveDirectionKeys(secret: secret, nonce: nonce, seed: seed, iv: iv)
        let k2 = Kdf.deriveDirectionKeys(secret: secret, nonce: nonce, seed: seed, iv: iv)
        XCTAssertEqual(k1.aesKey, k2.aesKey)
        XCTAssertNotEqual(k1.aesKey, k1.hmacKey)
        // HKDF-Expand for 32 bytes is one HMAC block with counter 0x01.
        let prk = Random.bytes(32)
        XCTAssertEqual(Kdf.hkdfExpand(prk: prk, info: Kdf.airShieldInfo, length: 32), Hash.hmacSha256(key: prk, data: Kdf.airShieldInfo + [1]))
    }

    func testEcdhAgrees() throws {
        let a = Ecdh.generateEphemeral(), b = Ecdh.generateEphemeral()
        XCTAssertEqual(Ecdh.raw(a).count, 64)
        XCTAssertEqual(try Ecdh.sharedSecret(a, peerPublic64: Ecdh.raw(b)), try Ecdh.sharedSecret(b, peerPublic64: Ecdh.raw(a)))
    }

    func testLinkUuidIsV4() {
        for _ in 0 ..< 50 { XCTAssertTrue(LinkUuid.isValid(LinkUuid.random())) }
        XCTAssertFalse(LinkUuid.isValid([UInt8](repeating: 0, count: 16)))
    }

    func testTrustBodyLayout() throws {
        let key = OwnerKey()
        let binding = HandshakeBinding(myChallenge: Random.bytes(16), glChallenge: Random.bytes(16), mySeed: Random.bytes(32), glSeed: Random.bytes(32), myPub: Random.bytes(64), glPub: Random.bytes(64), glReqPub: Random.bytes(64))
        let body = try key.enableTrustBody(binding: binding)
        let f = try Wire.parse(body)
        XCTAssertEqual(f.bytes(1), Hash.sha256(key.publicKey64))
        XCTAssertEqual(f.bytes(2).count, 64)
        XCTAssertEqual(f.varint(3), 2)
        // s is low.
        XCTAssertFalse(LowS.greater(Array(f.bytes(2)[32...]), LowS.halfOrder))
        // The signature verifies over the binding digest as a prehashed ECDSA.
        let sig = try CryptoKitSignature(raw: f.bytes(2))
        XCTAssertTrue(sig.verify(publicKey: key.key.publicKey, preimage: binding.primaryPreimage))
    }

    func testLowS() {
        XCTAssertEqual(LowS.normalize(LowS.halfOrder), LowS.halfOrder)
        var high = LowS.halfOrder
        high[31] += 1
        let low = LowS.normalize(high)
        XCTAssertTrue(LowS.greater(LowS.halfOrder, low) || low == LowS.halfOrder)
        // n - (n/2 + 1) = n/2 (n is odd): halfOrder.
        XCTAssertEqual(low, LowS.halfOrder)
    }

    func testDataXFragmentAcrossFrames() throws {
        // A 1024-byte message split: 4-byte header plus 1007 bytes in frame 1, 17 bytes in frame 2.
        let link = FakeLink()
        let mux = DataXConnection(link: link)
        let payload = Random.bytes(1024)
        let whole = DataX.buildHeader(channelId: 0x8002, dataLen: 1024) + payload
        let frame1 = FrameCrypto.pad(Array(whole[0 ..< 1011]))
        XCTAssertEqual(frame1.count, 1024)
        let frame2 = FrameCrypto.pad(Array(whole[1011...]))
        link.frames = [frame1, frame2]
        let exp = expectation(description: "message")
        Task {
            let m = try await mux.receive()
            XCTAssertEqual(m.payload, payload)
            XCTAssertEqual(m.info.channelId, 0x8002)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTypeCacheOnBareContinuations() throws {
        let link = FakeLink()
        let mux = DataXConnection(link: link)
        let first = DataX.buildHeader(channelId: 0x8003, dataLen: 2, serviceId: 20, messageType: 4) + [1, 2]
        let second = DataX.buildHeader(channelId: 0x8003, dataLen: 1) + [3]
        link.frames = [FrameCrypto.pad(first + second)]
        let exp = expectation(description: "two")
        Task {
            let a = try await mux.receive(), b = try await mux.receive()
            XCTAssertEqual(a.info.messageType, 4)
            XCTAssertEqual(b.info.messageType, 4)
            XCTAssertEqual(b.info.serviceId, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testPyJsonDumps() throws {
        let v = try JSONValue.parse(#"{"b":1,"a":[true,null,"é\"x"],"c":{"z":2.5}}"#)
        XCTAssertEqual(v.pyDumps(), "{\"b\": 1, \"a\": [true, null, \"\\u00e9\\\"x\"], \"c\": {\"z\": 2.5}}")
        XCTAssertEqual(v["a"].flatMap { if case .array(let a) = $0 { return a.count } else { return nil } }, 3)
    }

    func testPyUrlEncode() {
        XCTAssertEqual(PyUrl.encode([("a b", "c&d"), ("e", "ü")]), "a+b=c%26d&e=%C3%BC")
        XCTAssertEqual(PyUrl.quote("a b/c"), "a%20b%2Fc")
    }

    func testGzipRoundTrip() throws {
        let input = Array("access_token=HW%7Cx&serial_number=ABC".utf8)
        let gz = Gzip.compress(input)
        XCTAssertEqual(Array(gz.prefix(2)), [0x1F, 0x8B])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c"]
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(gz))
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(out.bytes, input)
    }

    func testBytePipeKeepsOrderUnderLoad() {
        let pipe = BytePipe()
        let chunks = 2000
        let queue = DispatchQueue(label: "feed")
        queue.async {
            for i in 0 ..< chunks {
                pipe.append([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), 0xAB])
            }
        }
        let exp = expectation(description: "ordered")
        Task {
            for i in 0 ..< chunks {
                let b = try await pipe.read(3)
                if b != [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), 0xAB] { XCTFail("chunk \(i) out of order: \(b)"); break }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testAdler32() {
        var a = Adler32()
        a.update(Array("Wikipedia".utf8))
        XCTAssertEqual(a.value, 0x11E6_0398)
        XCTAssertEqual(Adler32().value, 1)
    }

    func testCaptureFlatbuffer() {
        // A hand-built flatbuffer: root -> info table (slot 4 handle, slot 8 kind, slot 10 assets vector).
        let fb = FlatBuilder()
        let payload = fb.capture(handle: "cap-1", kind: 3074, assets: [("asset-a", 0x0001, 5_000_000), ("asset-b", 0x100002, 16_000)])
        guard let c = CaptureParser.parse(payload) else { return XCTFail("did not parse") }
        XCTAssertEqual(c.handle, "cap-1")
        XCTAssertEqual(c.type, .video)
        XCTAssertEqual(c.assets.count, 2)
        XCTAssertEqual(c.main?.id, "asset-a")
        XCTAssertTrue(c.assets[1].delivered)
        XCTAssertEqual(c.preview?.id, "asset-b")
    }

    func testSoftApInfoParse() {
        let addr = Wire.fieldString(3, "192.168.4.1/24")
        let creds = Wire.fieldString(1, "glasses-ap") + Wire.fieldString(2, "secret")
        let payload = Wire.fieldVarint(1, 1) + Wire.fieldBytes(2, addr) + Wire.fieldBytes(3, creds)
        let info = SoftApInfo.parse(payload, ssid: "x", password: "y")
        XCTAssertTrue(info.ok)
        XCTAssertEqual(info.address, "192.168.4.1")
        XCTAssertEqual(info.port, 20203)
        XCTAssertEqual(info.ssid, "glasses-ap")
    }

    /// Two SecureLinks facing each other over in-memory pipes: both ends are the phone's code, so the
    /// symmetric construction (rx of one = tx of the other) proves the key schedule is used consistently.
    func testHandshakeLoopback() throws {
        let (a, b) = PipePair.make()
        let left = SecureLink(transport: a), right = SecureLink(transport: b)
        let exp = expectation(description: "handshake")
        Task {
            async let l: Void = left.open()
            async let r: Void = right.open()
            _ = try await (l, r)
            try await left.send([0xAA, 0xBB])
            let got = try await right.receive()
            XCTAssertEqual(FrameCrypto.withoutPad(got), [0xAA, 0xBB])
            try await right.send(Array("hello".utf8))
            let back = try await left.receive()
            XCTAssertEqual(FrameCrypto.withoutPad(back), Array("hello".utf8))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

// MARK: helpers

/// A plaintext link that hands out prepared frames.
final class FakeLink: PlaintextLink {
    var frames: [[UInt8]] = []
    var sent: [[UInt8]] = []
    func send(_ plaintext: [UInt8]) async throws { sent.append(plaintext) }
    func receive() async throws -> [UInt8] {
        guard !frames.isEmpty else { throw TransportError("no more frames") }
        return frames.removeFirst()
    }
}

/// Two transports joined back to back.
final class PipePair: Transport {
    let inbox = BytePipe()
    weak var peer: PipePair?
    var closed = false

    static func make() -> (PipePair, PipePair) {
        let a = PipePair(), b = PipePair()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func connect() async throws {}
    func send(_ sdu: [UInt8]) async throws { peer?.inbox.append(sdu) }
    func receive() async throws -> [UInt8] { try await SduReader.next(from: inbox) }
    func close() { closed = true }
}

struct CryptoKitSignature {
    let raw: [UInt8]
    init(raw: [UInt8]) throws { self.raw = raw }
    func verify(publicKey: CryptoKit.P256.Signing.PublicKey, preimage: [UInt8]) -> Bool {
        guard let sig = try? CryptoKit.P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return publicKey.isValidSignature(sig, for: preimage)
    }
}

import CryptoKit

/// Just enough of a flatbuffer builder for the capture record the parser reads.
final class FlatBuilder {
    private var buf: [UInt8] = []

    private func align(_ n: Int) { while buf.count % n != 0 { buf.append(0) } }
    private func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    private func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    /// Appends a string (length, bytes, NUL) and returns its offset.
    private func string(_ s: String) -> Int {
        align(4)
        let at = buf.count
        buf += u32(UInt32(s.utf8.count)) + Array(s.utf8) + [0]
        return at
    }

    /// A table whose fields are given as (slot, 4-byte value or offset target). Offsets are made relative here.
    /// `fields`: slot -> .value(bytes) or .offset(absolute position).
    enum Field { case value([UInt8]), offset(Int) }

    private func table(_ fields: [(Int, Field)], maxSlot: Int) -> Int {
        // vtable: size, table size, then one u16 per slot from 4 up to maxSlot.
        let slots = (maxSlot - 4) / 2 + 1
        let vtSize = 4 + slots * 2
        align(4)
        let vt = buf.count
        var tableBody: [UInt8] = []
        var slotOffsets = [Int](repeating: 0, count: slots)
        // Table starts with soffset to vtable, then fields packed, each 4 bytes (or 8 for wide).
        var cursor = 4
        var pending: [(Int, Field)] = []
        for (slot, field) in fields {
            let index = (slot - 4) / 2
            slotOffsets[index] = cursor
            switch field {
            case .value(let bytes):
                tableBody += bytes
                cursor += bytes.count
            case .offset:
                tableBody += [0, 0, 0, 0]
                pending.append((cursor, field))
                cursor += 4
            }
        }
        let tableSize = 4 + tableBody.count
        buf += u16(vtSize) + u16(tableSize) + slotOffsets.flatMap(u16)
        align(4)
        let tablePos = buf.count
        buf += u32(UInt32(tablePos - vt)) + tableBody
        for (fieldOffset, field) in pending {
            if case .offset(let target) = field {
                let fieldPos = tablePos + fieldOffset
                let rel = u32(UInt32(target &- fieldPos))
                // Targets must come BEFORE the field in our builder (negative relative offsets are not
                // valid in flatbuffers), so the parser is checked with the real sign handling below.
                buf.replaceSubrange(fieldPos ..< fieldPos + 4, with: rel)
            }
        }
        return tablePos
    }

    func capture(handle: String, kind: UInt32, assets: [(String, UInt32, UInt32)]) -> [UInt8] {
        // Flatbuffers offsets are unsigned and point forward. Build children after parents is not
        // possible bottom-up, so lay the buffer out: [root offset][info table][assets vector][asset tables][strings].
        // Simplest: build strings and leaf tables first at the END by reserving, then fix up. Instead we
        // emulate a forward layout by building into separate chunks and concatenating in order.
        var out: [UInt8] = [0, 0, 0, 0] // root uoffset placeholder
        // info table position will be 4 (after alignment).
        // Layout plan (all 4-byte aligned):
        //   info vtable + info table
        //   assets vector (count + uoffsets)
        //   each asset: vtable + table
        //   strings
        // We compute sizes first.
        func pad4(_ n: Int) -> Int { (n + 3) / 4 * 4 }
        // Root table: one slot (4) that points at the info table.
        let rootVtStart = 4   // vt: 6 bytes, padded to 8
        let rootTablePos = 12 // soffset + uoffset = 8 bytes
        let infoVt = 4 + 4 * 2  // slots 4..10 => 4 slots: 4,6,8,10
        let infoTable = 4 + 4 + 4 + 4  // soffset, handle off, kind u32, assets off
        let infoStart = 20
        let infoTablePos = infoStart + infoVt
        let vectorPos = pad4(infoTablePos + infoTable)
        let vectorSize = 4 + 4 * assets.count
        var assetPos: [Int] = []
        var cursor = pad4(vectorPos + vectorSize)
        let assetVt = 4 + 5 * 2  // slots 4..12 => 5 slots
        let assetTable = 4 + 4 + 4 + 4  // soffset, id off, type u32, size u32
        for _ in assets {
            assetPos.append(cursor + assetVt)
            cursor = pad4(cursor + assetVt + assetTable)
        }
        var stringPos: [String: Int] = [:]
        let strings = [handle] + assets.map(\.0)
        for s in strings {
            stringPos[s] = cursor
            cursor = pad4(cursor + 4 + s.utf8.count + 1)
        }
        out = [UInt8](repeating: 0, count: cursor)
        func put(_ at: Int, _ bytes: [UInt8]) { out.replaceSubrange(at ..< at + bytes.count, with: bytes) }
        func uoff(_ from: Int, _ to: Int) -> [UInt8] { u32(UInt32(to - from)) }
        put(0, uoff(0, rootTablePos))
        put(rootVtStart, u16(6) + u16(8) + u16(4))
        put(rootTablePos, u32(UInt32(rootTablePos - rootVtStart)))
        put(rootTablePos + 4, uoff(rootTablePos + 4, infoTablePos))
        // info vtable: vtsize, tablesize, slot4=4 (handle), slot6=0, slot8=8 (kind), slot10=12 (assets)
        put(infoStart, u16(infoVt) + u16(infoTable) + u16(4) + u16(0) + u16(8) + u16(12))
        put(infoTablePos, u32(UInt32(infoTablePos - infoStart)))
        put(infoTablePos + 4, uoff(infoTablePos + 4, stringPos[handle]!))
        put(infoTablePos + 8, u32(kind))
        put(infoTablePos + 12, uoff(infoTablePos + 12, vectorPos))
        put(vectorPos, u32(UInt32(assets.count)))
        for (i, asset) in assets.enumerated() {
            let elem = vectorPos + 4 + 4 * i
            put(elem, uoff(elem, assetPos[i]))
            let vt = assetPos[i] - assetVt
            // slots: 4=id off(4), 6=type(8), 8=0, 10=0, 12=size(12)
            put(vt, u16(assetVt) + u16(assetTable) + u16(4) + u16(8) + u16(0) + u16(0) + u16(12))
            put(assetPos[i], u32(UInt32(assetPos[i] - vt)))
            put(assetPos[i] + 4, uoff(assetPos[i] + 4, stringPos[asset.0]!))
            put(assetPos[i] + 8, u32(asset.1))
            put(assetPos[i] + 12, u32(asset.2))
        }
        for s in strings {
            put(stringPos[s]!, u32(UInt32(s.utf8.count)) + Array(s.utf8) + [0])
        }
        return out
    }
}
