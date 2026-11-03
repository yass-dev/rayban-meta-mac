import XCTest
@testable import VisorKit

/// svc28 DeviceState payloads built by hand from the wiki's field tables (Device-state-and-build-info,
/// Glasses-hardware), and the shutter and clock messages checked against the bytes `Shutter.kt` / `Clock.kt` build.
final class DeviceStatusTests: XCTestCase {
    private func v(_ f: Int, _ x: UInt64) -> [UInt8] { Wire.fieldVarint(f, x) }
    private func m(_ f: Int, _ b: [UInt8]) -> [UInt8] { Wire.fieldBytes(f, b) }
    private func s(_ f: Int, _ t: String) -> [UInt8] { Wire.fieldString(f, t) }
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i ..< j], radix: 16)!)
            i = j
        }
        return out
    }

    /// The wiki's Gen 2 reading: 100 %, not charging, 4.48 V, 28.9 °C; case 80 % at firmware 12.14.7, COCOS;
    /// 20317 MB free of 21822 MB; worn, arms folded, camera ready.
    private var snapshot: [UInt8] {
        let battery = v(1, 1) + v(2, 4) + v(3, 100) + v(4, 28_900) + v(5, 4_480)
        let caseBattery = v(1, 1) + v(2, 0) + v(3, 80) + s(4, "<case-serial>") + s(5, "12.14.7") + v(7, 100) + v(8, 1) + v(9, 253)
        let hardware = v(1, 1) + v(2, 1) + v(3, 1) + v(4, 1) + v(5, 0) + v(6, 1)
        let led = v(1, 1) + v(2, 1) + v(3, 0) + v(4, 1)
        let thermal = v(1, 1) + v(2, 0) + v(3, 0) + v(4, 0)
        return m(1, battery) + m(2, caseBattery) + v(3, 5) + v(4, 1) + v(5, 2) + v(6, 2) + m(7, hardware) + m(8, led)
            + v(9, 1) + m(10, v(1, 0) + v(2, 0)) + v(11, 1) + m(12, v(1, 0) + v(2, 350) + v(3, 1)) + m(13, thermal)
            + v(14, 1) + m(15, v(1, 42) + v(2, 2)) + v(16, 0) + v(17, 0) + v(18, 0)
            + m(19, v(1, 3) + v(2, 3) + v(3, 4) + v(4, 1)) + m(20, v(1, 7)) + m(21, v(1, 20_317) + v(2, 21_822))
            + m(22, v(1, 11)) + m(22, v(1, 12)) + m(25, v(1, 9) + v(2, 1) + v(3, 60)) + v(26, 2)
            + m(27, v(1, 11) + v(2, 1)) + m(27, v(1, 12) + v(2, 3))
            + m(28, v(1, 3) + v(2, 2) + v(3, 4) + v(4, 1_700_000_000_000)) + v(29, 2) + m(31, v(1, 3))
            + v(35, 2) + v(36, 1) + v(37, 4) + v(39, 0) + s(10000, "11111111-2222-3333-4444-555555555555")
    }

    func testDecodeSnapshot() {
        let st = GlassesStatus.decode(snapshot)
        XCTAssertEqual(st.battery, .init(percent: 100, charging: false, chargeState: "NOT_CHARGING", health: "NORMAL", volts: 4.48, temperatureC: 28.9))
        XCTAssertEqual(st.batteryPercent, 100)
        XCTAssertEqual(st.charging, false)
        XCTAssertEqual(st.temperatureC, 28.9)
        XCTAssertEqual(st.caseBattery?.percent, 80)
        XCTAssertEqual(st.caseBatteryPercent, 80)
        XCTAssertEqual(st.caseBattery?.known, true)
        XCTAssertEqual(st.caseBattery?.firmware, "12.14.7")
        XCTAssertEqual(st.caseBattery?.platform, "COCOS")
        XCTAssertEqual(st.casePresent, true)
        XCTAssertEqual(st.camera, "CAPTURE_READY")
        XCTAssertEqual(st.recording, false)
        XCTAssertEqual(st.captureButton, "SHORT_PRESS_DOWN")
        XCTAssertEqual(st.captouch, "DOUBLE_TAP")
        XCTAssertEqual(st.hinge, "CLOSED")
        XCTAssertEqual(st.armsOpen, false)
        XCTAssertEqual(st.hardware?.speakerOk, false)
        XCTAssertEqual(st.hardware?.captouchOk, true)
        XCTAssertEqual(st.led?.privacyLedActive, true)
        XCTAssertEqual(st.mount, "DON")
        XCTAssertEqual(st.worn, true)
        XCTAssertEqual(st.deepSleepPending, false)
        XCTAssertEqual(st.storageLevel, "STABLE")
        XCTAssertEqual(st.tampering, .init(tampered: false, lux: 350, indoor: true))
        XCTAssertEqual(st.thermal?.health, "NORMAL")
        XCTAssertEqual(st.sessionVerified, true)
        XCTAssertEqual(st.peakPower, [.init(appId: 42, state: "THROTTLE_LEVEL_1")])
        XCTAssertEqual(st.bluetooth, .init(ancs: "CONNECTED", map: "CONNECTED", pbap: "DISCONNECTED", btc: "CONNECTED"))
        XCTAssertEqual(st.interruptedApp, 7)
        XCTAssertEqual(st.storageFreeMb, 20_317)
        XCTAssertEqual(st.storageTotalMb, 21_822)
        XCTAssertEqual(st.registeredApps, [11, 12])
        XCTAssertEqual(st.volume, .init(level: 9, percent: 60, stream: "MEDIA"))
        XCTAssertEqual(st.lockState, "UNLOCKED")
        XCTAssertEqual(st.apps, [.init(appId: 11, state: "ACTIVE"), .init(appId: 12, state: "PAUSED")])
        XCTAssertEqual(st.call, .init(state: "ACTIVE", callingState: "ACTIVE", platform: "WHATSAPP", startTimeMs: 1_700_000_000_000))
        XCTAssertEqual(st.actionButton, "SHORT_PRESS_UP")
        XCTAssertEqual(st.assistantAttention, "LISTENING")
        XCTAssertEqual(st.waterDetect, "NOT_DETECTED")
        XCTAssertEqual(st.cameraSensing, "OFF")
        XCTAssertEqual(st.odc, "STOPPED")
        XCTAssertEqual(st.overhead, false)
        XCTAssertEqual(st.interactionKey, "11111111-2222-3333-4444-555555555555")

        let byKey = Dictionary(uniqueKeysWithValues: st.fields.map { ($0.key, $0) })
        XCTAssertEqual(byKey["batteryPercent"]?.value, "100%")
        XCTAssertEqual(byKey["batteryPercent"]?.label, "Battery")
        XCTAssertEqual(byKey["batteryVoltage"]?.value, "4.48 V")
        XCTAssertEqual(byKey["batteryTemperature"]?.value, "28.9 °C")
        XCTAssertEqual(byKey["caseBattery"]?.value, "80%")
        XCTAssertEqual(byKey["worn"]?.value, "Yes")
        XCTAssertEqual(byKey["hinge"]?.value, "Folded")
        XCTAssertEqual(byKey["camera"]?.value, "Capture ready")
        XCTAssertEqual(byKey["storageFree"]?.value, "20317 MB")
    }

    /// After a long time out of the case: level -1 as five bytes 0xFFFFFFFF, empty serial, firmware 0.0.0, scale absent.
    func testEmptyCaseReading() {
        let payload = m(2, v(3, 0xFFFF_FFFF) + s(4, "") + s(5, "0.0.0") + v(8, 0))
        XCTAssertEqual(Array(v(3, 0xFFFF_FFFF).dropFirst()).count, 5)
        let c = GlassesStatus.decode(payload).caseBattery!
        XCTAssertEqual(c.level, -1)
        XCTAssertEqual(c.scale, 4)
        XCTAssertFalse(c.known)
        XCTAssertNil(c.percent)
        XCTAssertNil(c.serial)
        XCTAssertNil(c.firmware)
        XCTAssertFalse(c.present)
        // Sign-extended to ten bytes reads the same.
        XCTAssertEqual(GlassesStatus.decode(m(2, v(3, UInt64.max))).caseBattery?.level, -1)
        // Bars: known, no percentage.
        let bars = GlassesStatus.decode(m(2, v(3, 3))).caseBattery!
        XCTAssertTrue(bars.known)
        XCTAssertNil(bars.percent)
        XCTAssertEqual(GlassesStatus.decode(m(2, v(3, 3))).fields.first { $0.key == "caseBattery" }?.value, "3/4 bars")
    }

    func testPartialPushOnlyCarriesItsFields() {
        let st = GlassesStatus.decode(m(1, v(2, 1) + v(3, 57)))
        XCTAssertEqual(st.batteryPercent, 57)
        XCTAssertEqual(st.charging, true)
        XCTAssertNil(st.mount)
        XCTAssertNil(st.worn)
        XCTAssertNil(st.storageFreeMb)
        XCTAssertEqual(StatusEnums.name(StatusEnums.camera, 99), "UNKNOWN_99")
    }

    func testHubMergesPushesIntoSnapshot() {
        let hub = StatusHub()
        XCTAssertNil(hub.ingest(messageType: StatusMsg.subscribeAck, payload: [0x08, 0x01]))
        hub.ingest(messageType: 2005, payload: snapshot)
        hub.ingest(messageType: 2007, payload: m(1, v(1, 1) + v(2, 1) + v(3, 99) + v(4, 30_000) + v(5, 4_300)))
        hub.ingest(messageType: 2015, payload: v(9, 2))
        let st = hub.ingest(messageType: 2009, payload: v(3, 2))!
        XCTAssertEqual(st.batteryPercent, 99)
        XCTAssertEqual(st.charging, true)
        XCTAssertEqual(st.worn, false)
        XCTAssertEqual(st.recording, true)
        XCTAssertEqual(st.storageFreeMb, 20_317)
        XCTAssertEqual(st.caseBatteryPercent, 80)
        XCTAssertEqual(st.registeredApps, [11, 12])
        XCTAssertEqual(st.lastMessageType, 2009)
        XCTAssertEqual(st.lastKind, "camera")
        // A repeated field is replaced as a whole.
        XCTAssertEqual(hub.ingest(messageType: 2029, payload: m(22, v(1, 5)))?.registeredApps, [5])

        let info = DeviceInfo(build: "Meta/hammerhead/greathammerhead:14/UKQ1.250303.001/70523680060800100:user/release-keys",
                              serial: "<serial>", deviceUuid: "not-a-uuid", bluetoothAddress: "AA:BB:CC:DD:EE:FF", model: "greathammerhead")
        let withInfo = hub.ingest(info: info)
        XCTAssertEqual(withInfo.firmwareVersion, "70523680060800100")
        XCTAssertEqual(withInfo.model, "greathammerhead")
        XCTAssertNil(withInfo.deviceUuid)
        XCTAssertEqual(withInfo.batteryPercent, 99)
        XCTAssertEqual(withInfo.fields.first?.key, "model")
    }

    func testHubWaiterAndWatcher() async throws {
        let hub = StatusHub()
        var seen: [Int?] = []
        let id = hub.addWatcher { seen.append($0.batteryPercent) }
        let w = hub.expect { _, fields, _ in fields.has(3) && fields.varint(3) == 1 }
        hub.ingest(messageType: 2009, payload: v(3, 5)) // not the photo
        hub.ingest(messageType: 2007, payload: m(1, v(3, 40)))
        hub.ingest(messageType: 2009, payload: v(3, 1))
        let got = try await hub.collect(w, timeout: 1)
        XCTAssertEqual(got?.camera, "CAPTURE_PHOTO_STARTED")
        hub.removeWatcher(id)
        hub.ingest(messageType: 2007, payload: m(1, v(3, 41)))
        XCTAssertEqual(seen, [nil, 40, 40])

        let never = hub.expect { _, _, _ in false }
        let start = Date()
        let none = try await hub.collect(never, timeout: 0.2)
        XCTAssertNil(none)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStatusEncodesWithoutNils() throws {
        let json = String(decoding: try JSONEncoder().encode(GlassesStatus.decode(v(9, 1))), as: UTF8.self)
        XCTAssertTrue(json.contains("\"worn\":true"))
        XCTAssertTrue(json.contains("\"fields\":["))
        XCTAssertFalse(json.contains("batteryPercent"))
    }

    func testBuildFingerprint() {
        XCTAssertEqual(BuildFingerprint.firmwareVersion("Meta/hammerhead/greathammerhead:14/UKQ1.250303.001/70523680060800100:user/release-keys"), "70523680060800100")
        XCTAssertNil(BuildFingerprint.firmwareVersion("garbage"))
        XCTAssertTrue(BuildFingerprint.isUuidShaped("12345678-1234-1234-1234-123456789abc"))
        XCTAssertFalse(BuildFingerprint.isUuidShaped("12345678-1234-1234-1234123456789abcd"))
    }

    // MARK: messages the Mac sends

    func testSubscribeBytes() {
        // buildSubscribe: fieldBytes(1, encodeVarint(1)) + fieldBytes(2, key).
        XCTAssertEqual(StatusMsg.subscribePayload(interactionKey: "11111111-2222-3333-4444-555555555555").hex,
                       "0a0101122431313131313131312d323232322d333333332d343434342d353535353535353535353535")
    }

    func testShutterIntentBytes() {
        XCTAssertEqual(Shutter.stopVideoIntent().hex,
                       "0a37636f6d2e6d6574612e736d617274676c6173732e6170702e696e74656e742e616374696f6e2e434c4f53455f4150505f43415054555245")
        XCTAssertEqual(Shutter.startVideoIntent(.hyperlapse).hex,
                       "0a3d636f6d2e6d6574612e736d617274676c6173732e6170702e696e74656e742e616374696f6e2e4147454e5449435f53544152545f5245434f5244494e47"
                       + "121a0a0c636170747572655f747970652a0a68797065726c61707365")
        XCTAssertEqual(Shutter.photoIntent().hex,
                       "0a16616374696f6e2e726f62757374612e63617074757265"
                       + "12500a2d636f6d2e6d6574612e736d617274676c6173732e696e74656e742e616374696f6e2e4c41554e43485f54595045"
                       + "2a1f434150545552455f45585452415f4c41554e43485f545950455f50484f544f"
                       + "12320a22616e64726f69642e696e74656e742e65787472612e52454645525245525f4e414d452a0c53484f52545f425554544f4e"
                       + "120c0a0849535f4d4f44414c1001")
        // The default video intent carries capture_type "video".
        let extra = Wire.parseLenient(Wire.parseLenient(Shutter.startVideoIntent()).bytes(2))
        XCTAssertEqual(extra.string(1), "capture_type")
        XCTAssertEqual(extra.string(5), "video")
        XCTAssertEqual(Shutter.snIntent, 2300)
    }

    func testClockBytes() {
        // 1700000000.123 s: Timestamp {1: 1700000000, 2: 123000000}, zone, then the 16-byte request uuid.
        let payload = ClockSync.payload(nowMillis: 1_700_000_000_123, zone: "Europe/Paris", requestId: Array(0 ..< 16))
        XCTAssertEqual(payload.hex, "0a0b0880e2cfaa0610c0a9d33a120c4575726f70652f50617269731a10000102030405060708090a0b0c0d0e0f")
        // Math.floorDiv / floorMod for times before 1970.
        let ts = Wire.parseLenient(Wire.parseLenient(ClockSync.payload(nowMillis: -1, zone: "UTC", requestId: [])).bytes(1))
        XCTAssertEqual(Int64(bitPattern: ts.varint(1)), -1)
        XCTAssertEqual(ts.varint(2), 999_000_000)
        XCTAssertEqual(ServiceIds.deviceInfo, 22)
        XCTAssertEqual(ClockSync.deviceInfoRequest, 1)
    }

    func testSessionNotConnected() async {
        let session = GlassesSession(transport: BytePipeTransportStub(), ownerKey: nil)
        do { try await session.syncClock(); XCTFail("expected an error") } catch {}
        do { try await session.takePhoto(timeout: 0.1); XCTFail("expected an error") } catch {}
    }
}

/// A transport that never connects: enough to check the calls refuse without a link.
private final class BytePipeTransportStub: Transport {
    func connect() async throws { throw TransportError("stub") }
    func send(_ sdu: [UInt8]) async throws { throw TransportError("stub") }
    func receive() async throws -> [UInt8] { throw TransportError("stub") }
    func close() {}
}
