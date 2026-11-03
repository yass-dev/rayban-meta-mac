import XCTest
@testable import VisorKit

/// svc31 writes and svc33 (RLDrive) syncs. The golden hex is what Visor's Kotlin (`encodeWrite`, `buildSync`,
/// `chunks` in GlassesSettings.kt and RlDrive.kt) produces for the same inputs.
final class SettingsTests: XCTestCase {

    private let uuidNs = "0123abcd-0000-4000-8000-00000000beef@individual_device_settings"

    private func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i ..< j], radix: 16)!)
            i = j
        }
        return out
    }

    private func d(_ key: String) -> SettingDescriptor { SettingsCatalog.byKey[key]! }

    // MARK: svc31 write bodies

    func testSvc31WriteBodies() throws {
        XCTAssertEqual(d("assistant_enabled").svc31Payload(.bool(true))?.hex, "1001")
        XCTAssertEqual(d("wakeword_enabled").svc31Payload(.bool(false))?.hex, "a00200")
        XCTAssertEqual(d("video_duration_ms").svc31Payload(.int(60000))?.hex, "8801e0d403")
        XCTAssertEqual(d("quick_actions").svc31Payload(.string("voice"))?.hex, "d20605766f696365")
        // float: fixed64, wire type 1, little-endian double.
        XCTAssertEqual(d("audio_balance").svc31Payload(.double(-0.4))?.hex, "890e9a9999999999d9bf")
        // A negative int goes out as the ten-byte two's complement (capture_button_short_long_press is field 7).
        XCTAssertEqual(d("capture_button_short_long_press").svc31Payload(.int(-1))?.hex, "38ffffffffffffffffff01")
        // No svc31 field: RLDrive only.
        XCTAssertNil(d("sg_do_not_disturb").svc31Payload(.bool(true)))
        XCTAssertTrue(d("sg_do_not_disturb").wire.viaDrive)
        // A field this firmware does not parse also goes through RLDrive.
        XCTAssertTrue(d("smart_reply_enabled").wire.viaDrive)
        XCTAssertFalse(d("assistant_enabled").wire.viaDrive)
    }

    func testDriveText() {
        XCTAssertEqual(d("sg_do_not_disturb").text(.bool(true)), "true")
        XCTAssertEqual(d("capture_aspect_ratio").text(.int(1)), "1")
        XCTAssertEqual(d("audio_balance").text(.double(-0.4)), "-0.4")
        XCTAssertEqual(d("audio_balance").text(.double(1)), "1")
        XCTAssertEqual(SettingText.number(0.25), "0.25")
    }

    // MARK: RLDrive sync messages

    func testRound0FullRead() {
        let m = RlDrive.buildSync(namespace: uuidNs, requestId: "req-1", round: 0)
        XCTAssertEqual(m.hex, "080112980282012e5a280a2435663163306465302d373631352d346130652d396431652d303030303030303030303031100062026b768201395a280a2435663163306465302d373631352d346130652d396431652d3030303030303030303030311000620d73796e635f6d657461646174618201315a280a2435663163306465302d373631352d346130652d396431652d303030303030303030303031100062056d656469618801009201057265712d31980101a2013f30313233616263642d303030302d343030302d383030302d30303030303030306265656640696e646976696475616c5f6465766963655f73657474696e6773aa012435663163306465302d373631352d346130652d396431652d303030303030303030303031323f30313233616263642d303030302d343030302d383030302d30303030303030306265656640696e646976696475616c5f6465766963655f73657474696e6773")
    }

    private let pushKnown = DriveVersions([.init("kv", [.init("a1b2c3d4-0000-0000-0000-000000000009", 7), .init(RlDrive.localWriter, 2)])])
    private let pushHex = "080112f4018201a3015a280a2461316232633364342d303030302d303030302d303030302d30303030303030303030303910075a280a2435663163306465302d373631352d346130652d396431652d303030303030303030303031100362026b766a49321d0a1173675f646f5f6e6f745f6469737475726212026b761a04747275653a280a2435663163306465302d373631352d346130652d396431652d30303030303030303030303110038801029201057265712d32980101a201156c6f63616c5f6465766963655f73657474696e6773aa012435663163306465302d373631352d346130652d396431652d30303030303030303030303132156c6f63616c5f6465766963655f73657474696e6773"

    func testRound2WithPush() {
        // Our writer was at 2: the pushed object is version 3, and our counter goes to 3 in place.
        let m = RlDrive.buildSync(namespace: "local_device_settings", requestId: "req-2", round: 2, known: pushKnown,
                                  types: pushKnown.typeNames + ["kv"], push: [.kv("sg_do_not_disturb", "true")])
        XCTAssertEqual(m.hex, pushHex)
    }

    func testRound2EchoOnly() {
        let known = DriveVersions([.init("kv", [.init("glasses", 3)]), .init("sync_metadata", [.init("glasses", 1)])])
        let m = RlDrive.buildSync(namespace: "shared_settings_namespace_1", requestId: "req-3", round: 2, known: known, types: known.typeNames + ["kv"])
        XCTAssertEqual(m.hex, "080112da0182013b5a0b0a07676c617373657310035a280a2435663163306465302d373631352d346130652d396431652d303030303030303030303031100062026b768201465a0b0a07676c617373657310015a280a2435663163306465302d373631352d346130652d396431652d3030303030303030303030311000620d73796e635f6d657461646174618801029201057265712d33980101a2011b7368617265645f73657474696e67735f6e616d6573706163655f31aa012435663163306465302d373631352d346130652d396431652d303030303030303030303031321b7368617265645f73657474696e67735f6e616d6573706163655f31")
    }

    func testChunksAndReassembly() {
        let whole = hex(pushHex)
        let pieces = RlDrive.chunks(whole, max: 100, chunkId: "chunk-1")
        XCTAssertEqual(pieces.map(\.hex), [
            "080512648201a3015a280a2461316232633364342d303030302d303030302d303030302d30303030303030303030303910075a280a2435663163306465302d373631352d346130652d396431652d303030303030303030303031100362026b766a49321d0a1173672a076368756e6b2d3132156c6f63616c5f6465766963655f73657474696e677338034000",
            "080512645f646f5f6e6f745f6469737475726212026b761a04747275653a280a2435663163306465302d373631352d346130652d396431652d30303030303030303030303110038801029201057265712d32980101a201156c6f63616c5f6465766963655f7365742a076368756e6b2d3132156c6f63616c5f6465766963655f73657474696e677338034001",
            "0805122c74696e6773aa012435663163306465302d373631352d346130652d396431652d3030303030303030303030312a076368756e6b2d3132156c6f63616c5f6465766963655f73657474696e677338034002",
        ])
        XCTAssertEqual(RlDrive.chunks(whole).count, 1, "under a kilobyte goes whole")

        // Out of order, and the first piece without its index, as the glasses send it.
        let first = Wire.fieldVarint(1, 5) + Wire.fieldBytes(2, Wire.parseLenient(pieces[0]).bytes(2)) + Wire.fieldString(5, "chunk-1")
            + Wire.fieldString(6, "local_device_settings") + Wire.fieldVarint(7, 3)
        let a = RlDriveAssembler()
        XCTAssertNil(a.assemble(pieces[2]))
        XCTAssertNil(a.assemble(first))
        XCTAssertEqual(a.assemble(pieces[1]), whole)
        XCTAssertEqual(a.assemble(whole), whole, "a whole message passes through")
    }

    // MARK: replies

    /// A glasses reply built from the wiki's field tables: RLDriveMessage {1 type, 2 SyncMessage, 6 namespace},
    /// SyncMessage {16 TypeData, 17 round, 18 request id, 20 namespace, 21 peer, 22 terminated},
    /// TypeData {11 version, 12 typename, 13 InternalObject {6 RLDriveObject {1 uri, 2 type, 3 data, 8 deleted}, 7 version}}.
    private func reply(_ namespace: String, _ requestId: String, round: UInt64, terminated: Bool = false, kv: [(String, String, Bool)] = [],
                       writers: [(String, UInt64)] = [("glasses-writer", 12)]) -> [UInt8] {
        var typeData: [UInt8] = []
        for (w, v) in writers { typeData += Wire.fieldBytes(11, Wire.fieldString(1, w) + Wire.fieldVarint(2, v)) }
        typeData += Wire.fieldString(12, "kv")
        for (i, (uri, data, deleted)) in kv.enumerated() {
            let obj = Wire.fieldString(1, uri) + Wire.fieldString(2, "kv") + Wire.fieldString(3, data) + (deleted ? Wire.fieldVarint(8, 1) : [])
            typeData += Wire.fieldBytes(13, Wire.fieldBytes(6, obj) + Wire.fieldBytes(7, Wire.fieldString(1, "glasses-writer") + Wire.fieldVarint(2, UInt64(i + 1))))
        }
        let meta = Wire.fieldBytes(11, Wire.fieldString(1, "glasses-writer") + Wire.fieldVarint(2, 1)) + Wire.fieldString(12, "sync_metadata")
        var sync = Wire.fieldBytes(16, typeData) + Wire.fieldBytes(16, meta) + Wire.fieldVarint(17, round) + Wire.fieldString(18, requestId)
            + Wire.fieldVarint(19, 1) + Wire.fieldString(20, namespace) + Wire.fieldString(21, "glasses-writer")
        if terminated { sync += Wire.fieldVarint(22, 1) }
        return Wire.fieldVarint(1, 1) + Wire.fieldBytes(2, sync) + Wire.fieldString(6, namespace)
    }

    func testDecodeRound1Reply() {
        let r = RlDrive.decodeSync(reply(uuidNs, "req-1", round: 1, kv: [
            ("video_duration_ms", "60000", false), ("assistant_enabled", "true", false), ("eis_mode", "", true),
        ]))
        XCTAssertEqual(r.namespace, uuidNs)
        XCTAssertEqual(r.round, 1)
        XCTAssertFalse(r.terminated)
        XCTAssertEqual(r.requestId, "req-1")
        XCTAssertEqual(r.versions.typeNames, ["kv", "sync_metadata"])
        XCTAssertEqual(r.versions.writers("kv"), [.init("glasses-writer", 12)])
        XCTAssertEqual(r.objects.map(\.uri), ["video_duration_ms", "assistant_enabled", "eis_mode"])
        XCTAssertEqual(r.objects[0].data, "60000")
        XCTAssertTrue(r.objects[2].deleted)

        var read = DriveNamespaceRead()
        read.objects = r.objects
        XCTAssertEqual(read.kv, ["video_duration_ms": "60000", "assistant_enabled": "true"])
    }

    func testChunkedReplyDecodes() {
        // A long reply in pieces: decoding piece 0 alone finds nothing, the joined message finds every object.
        let kv = (0 ..< 40).map { ("key_\($0)", String(repeating: "x", count: 40), false) }
        let whole = reply(uuidNs, "req-9", round: 1, kv: kv)
        let pieces = RlDrive.chunks(whole, chunkId: "c")
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(RlDrive.decodeSync(pieces[0]).objects.isEmpty)
        let a = RlDriveAssembler()
        var joined: [UInt8]?
        for p in pieces { joined = a.assemble(p) ?? joined }
        XCTAssertEqual(RlDrive.decodeSync(joined!).objects.count, 40)
    }

    func testSyncStateRunsTheRounds() {
        let s = DriveSync(requests: ["req-2": "local_device_settings", "req-3": "shared_settings_namespace_1"],
                          push: ["local_device_settings": [.kv("sg_do_not_disturb", "true")]])
        // Round 1 from the glasses: we answer round 2 with their versions and our push.
        let r1 = reply("local_device_settings", "req-2", round: 1, kv: [("sg_do_not_disturb", "false", false)],
                       writers: [("a1b2c3d4-0000-0000-0000-000000000009", 7), (RlDrive.localWriter, 2)])
        let round2 = s.take(RlDrive.decodeSync(r1))!
        let decoded = RlDrive.decodeSync(round2)
        XCTAssertEqual(decoded.round, 2)
        XCTAssertEqual(decoded.requestId, "req-2")
        XCTAssertEqual(decoded.versions.writers("kv"), [.init("a1b2c3d4-0000-0000-0000-000000000009", 7), .init(RlDrive.localWriter, 3)])
        XCTAssertEqual(decoded.objects.map(\.data), ["true"])
        XCTAssertNil(s.take(RlDrive.decodeSync(reply("other", "unknown-req", round: 1))), "a reply to someone else's request is ignored")
        XCTAssertNil(s.take(RlDrive.decodeSync(reply("local_device_settings", "req-2", round: 3, terminated: true))))
        let r3 = reply("shared_settings_namespace_1", "req-3", round: 1)
        XCTAssertNotNil(s.take(RlDrive.decodeSync(r3)))
        XCTAssertNil(s.take(RlDrive.decodeSync(reply("shared_settings_namespace_1", "req-3", round: 3, terminated: true))))
        let result = s.result
        XCTAssertEqual(result["local_device_settings"]?.kv, ["sg_do_not_disturb": "false"])
        XCTAssertEqual(result["local_device_settings"]?.finished, true)
        XCTAssertEqual(result["shared_settings_namespace_1"]?.answered, true)
        let done = expectation(description: "wait returns once every namespace terminated")
        Task { await s.wait(); done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: values

    func testStoredTextAsValues() {
        XCTAssertEqual(d("assistant_enabled").value(fromText: "true"), .bool(true))
        XCTAssertEqual(d("assistant_enabled").value(fromText: "1"), .bool(true))
        XCTAssertEqual(d("assistant_enabled").value(fromText: "false"), .bool(false))
        XCTAssertEqual(d("video_duration_ms").value(fromText: " 60000 "), .int(60000))
        XCTAssertEqual(d("audio_balance").value(fromText: "-0.4"), .double(-0.4))
        XCTAssertEqual(d("quick_actions").value(fromText: "voice"), .string("voice"))
        XCTAssertEqual(d("video_duration_ms").value(fromText: "garbage"), .string("garbage"))
        XCTAssertEqual(d("video_duration_ms").defaultValue, .int(180000))
        XCTAssertEqual(d("wakeword_enabled").defaultValue, .bool(true))
        XCTAssertEqual(d("quick_actions").defaultValue, .string(""))
        XCTAssertEqual(guessSetting("true"), .bool(true))
        XCTAssertEqual(guessSetting("42"), .int(42))
        XCTAssertEqual(guessSetting("0.5"), .double(0.5))
        XCTAssertEqual(guessSetting("en_GB"), .string("en_GB"))
        XCTAssertTrue(SettingText.same(.int, " 3", "3"))
        XCTAssertTrue(SettingText.same(.bool, "1", "true"))
        XCTAssertFalse(SettingText.same(.str, "a", "b"))
        XCTAssertEqual(RlDrive.namespace("individual_device_settings", deviceUuid: "u"), "u@individual_device_settings")
        XCTAssertEqual(RlDrive.namespace("local_device_settings", deviceUuid: "u"), "local_device_settings")
    }

    func testSettingRawJsonRoundTrip() throws {
        let values: [String: SettingRaw] = ["a": .bool(true), "b": .int(-7), "c": .double(0.25), "d": .string("hé"), "e": .int(180000)]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([String: SettingRaw].self, from: data), values)
        // Plain scalars on the wire.
        XCTAssertEqual(String(data: try JSONEncoder().encode([SettingRaw.bool(false), .int(3), .string("x"), .double(1.5)]), encoding: .utf8), #"[false,3,"x",1.5]"#)
        XCTAssertEqual(try JSONDecoder().decode([SettingRaw].self, from: Data(#"[true, 12, 0.5, "voice"]"#.utf8)), [.bool(true), .int(12), .double(0.5), .string("voice")])
        XCTAssertThrowsError(try JSONDecoder().decode([SettingRaw].self, from: Data("[null]".utf8)))
    }

    // MARK: catalogue

    func testCatalogue() throws {
        let all = SettingsCatalog.all
        XCTAssertEqual(Set(all.map(\.key)).count, all.count, "keys are unique")
        for s in all {
            XCTAssertTrue(["bool", "int", "double", "enum", "string"].contains(s.kind), s.key)
            XCTAssertFalse(s.label.isEmpty, s.key)
            if s.kind == "enum" { XCTAssertFalse(s.options?.isEmpty ?? true, s.key) }
            if s.writable, !s.wire.viaDrive, let def = s.defaultValue, s.kind != "string" {
                XCTAssertNotNil(s.svc31Payload(def), "\(s.key) default encodes")
            }
        }
        // Never offered, never writable.
        for key in ["sg_disable_thermal_shutdown", "cloud_ota_factory_reset_after_check", "developer_mode", "wifi_password", "homer_reset_enabled"] {
            XCTAssertNil(SettingsCatalog.byKey[key], key)
        }
        XCTAssertFalse(d("cloud_ota_enabled").writable)
        XCTAssertFalse(d("verified_session_enabled").writable)
        let json = String(data: try JSONEncoder().encode([d("video_duration_ms")]), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""kind":"enum""#))
        XCTAssertTrue(json.contains(#""default":180000"#))
        XCTAssertTrue(json.contains(#"{"value":60000,"label":"1 minute"}"#) || json.contains(#"{"label":"1 minute","value":60000}"#))
        XCTAssertFalse(json.contains("wire"))
    }

    // MARK: write refusals

    func testWriteRefusals() {
        func refused(_ key: String, _ value: SettingRaw) -> SettingsError? {
            do { _ = try checkSettingWrite(key, value); return nil } catch { return error as? SettingsError }
        }
        XCTAssertEqual(refused("sg_disable_thermal_shutdown", .bool(true)), .unknownKey("sg_disable_thermal_shutdown"))
        XCTAssertEqual(refused("nonsense", .bool(true)), .unknownKey("nonsense"))
        XCTAssertEqual(refused("cloud_ota_enabled", .bool(true)), .readOnly("cloud_ota_enabled"))
        XCTAssertEqual(refused("assignable_action_button_short_press_mapping", .int(2)), .readOnly("assignable_action_button_short_press_mapping"))
        XCTAssertEqual(refused("assistant_enabled", .int(1)), .wrongType(key: "assistant_enabled", expected: "bool"))
        XCTAssertEqual(refused("assistant_enabled", .string("true")), .wrongType(key: "assistant_enabled", expected: "bool"))
        XCTAssertNotNil(refused("notification_volume", .int(200)))
        XCTAssertNotNil(refused("notification_volume", .int(54)))
        XCTAssertNotNil(refused("notification_volume", .double(80)))
        XCTAssertNil(refused("notification_volume", .int(127)))
        XCTAssertNotNil(refused("video_duration_ms", .int(5000)), "hidden option")
        XCTAssertNotNil(refused("video_duration_ms", .string("60000")))
        XCTAssertNil(refused("video_duration_ms", .int(600000)))
        XCTAssertNotNil(refused("quick_actions", .string("email")))
        XCTAssertNil(refused("quick_actions", .string("call")))
        XCTAssertNotNil(refused("audio_balance", .double(0.3)), "off the 0.2 step")
        XCTAssertNotNil(refused("audio_balance", .double(1.2)))
        XCTAssertNotNil(refused("audio_balance", .double(.nan)))
        XCTAssertNil(refused("audio_balance", .double(0.6)))
        XCTAssertNil(refused("audio_balance", .int(-1)))
        XCTAssertNotNil(refused("action_button_assistant_custom_prompt", .string(String(repeating: "a", count: 101))))
        XCTAssertNotNil(refused("action_button_assistant_custom_prompt", .string("a\nb")))
        XCTAssertNil(refused("action_button_assistant_custom_prompt", .string("quel temps fait-il ?")))
        XCTAssertEqual(try? checkSettingWrite("audio_balance", .double(0.6000000001)).1, .double(0.6))
    }

    func testSessionWriteRefusesBeforeSending() async {
        let transport = RecordingTransport()
        let session = GlassesSession(transport: transport, ownerKey: nil)
        for (key, value) in [("sg_disable_thermal_shutdown", SettingRaw.bool(true)), ("cloud_ota_enabled", .bool(true)), ("notification_volume", .int(1000))] {
            do {
                try await session.writeSetting(key, value, timeout: 1)
                XCTFail("\(key) was accepted")
            } catch {
                XCTAssertTrue(error is SettingsError, "\(key): \(error)")
            }
        }
        XCTAssertEqual(transport.sent, 0)
    }
}

private final class RecordingTransport: Transport {
    var sent = 0
    func connect() async throws {}
    func send(_ sdu: [UInt8]) async throws { sent += 1 }
    func receive() async throws -> [UInt8] { throw SessionError("no glasses") }
    func close() {}
}
