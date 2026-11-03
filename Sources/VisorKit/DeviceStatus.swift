import Foundation

/// Device state (svc28), build info (svc100) and clock (svc22). Port of Visor's `Status.kt`,
/// `GlassesState.kt` (the device + info merge), `DeviceInfo.kt` and `Clock.kt`.

extension ServiceIds {
    /// `smartglasses_device_info`: where the phone sets the glasses' clock.
    public static let deviceInfo = 22
}

/// svc28 (`smartglasses_appmanager`) message types.
public enum StatusMsg {
    /// Phone to glasses: CompanionDeviceInit, the subscribe. Sent again on the same channel, it brings a fresh snapshot.
    public static let subscribe = 1000
    /// Glasses to phone: the two-byte acknowledgement of a subscribe.
    public static let subscribeAck = 1001
    /// Glasses to phone: the full DeviceState snapshot.
    public static let deviceState = 2005
    /// Subscription bit for DEVICE_STATE in field 1 of the subscribe.
    public static let subscriptionDeviceState: UInt64 = 1

    /// Every svc28 type that carries a DeviceState. 2005 is the snapshot; the rest name one field. The fields a
    /// message carries decide what it updates, not its type.
    public static let deviceStateTypes: [Int: String] = [
        2005: "device_state", 2006: "device_state_update", 2007: "battery",
        2008: "case_battery", 2009: "camera", 2010: "capture_button", 2011: "captouch",
        2012: "hinge", 2013: "hardware", 2014: "led", 2015: "mount", 2016: "power",
        2017: "storage", 2018: "tampering", 2019: "thermal", 2020: "verified_session",
        2021: "peak_power", 2022: "audio_active", 2023: "streaming_active",
        2024: "hot_car", 2025: "bluetooth", 2026: "app_interrupt",
        2027: "storage_details", 2028: "device_lock", 2029: "registered_apps",
        2030: "emg_battery", 2031: "emg_band_tightness", 2032: "volume", 2033: "apps",
        2034: "call", 2035: "action_button", 2036: "emg_band_tightness_state",
        2037: "assistant_attention", 2039: "peak_power_throttling",
        2040: "emg_band_orientation", 2041: "water_detect", 2042: "camera_sensing",
        2043: "odc", 2044: "verified_session_info",
    ]

    public static func isDeviceState(_ messageType: Int) -> Bool { deviceStateTypes[messageType] != nil }

    /// CompanionDeviceInit: field 1 the packed subscription varint, field 2 the interaction key.
    public static func subscribePayload(interactionKey: String) -> [UInt8] {
        Wire.fieldBytes(1, Wire.varint(subscriptionDeviceState)) + Wire.fieldString(2, interactionKey)
    }
}

/// The enum tables of the DeviceState proto, value to name.
public enum StatusEnums {
    public static let chargeState: [UInt64: String] = [0: "NO_DATA", 1: "CHARGING", 2: "CHARGING_FULL", 3: "CHARGING_LOW", 4: "NOT_CHARGING"]
    static let chargingStates: Set<String> = ["CHARGING", "CHARGING_FULL", "CHARGING_LOW"]
    public static let batteryHealth: [UInt64: String] = [0: "UNKNOWN", 1: "NORMAL", 2: "WARNING", 3: "CRITICAL", 4: "SHUTDOWN", 5: "EMERGENCY_SHUTDOWN"]
    public static let mount: [UInt64: String] = [0: "NONE", 1: "DON", 2: "DOFF"]
    public static let camera: [UInt64: String] = [
        0: "NO_STATE", 1: "CAPTURE_PHOTO_STARTED", 2: "CAPTURE_VIDEO_STARTED", 3: "CAPTURE_COMPLETED",
        4: "CAPTURE_FAILED", 5: "CAPTURE_READY", 6: "CAMERA_FAILING", 7: "CAPTURE_PREVIEW_STARTED",
        8: "CAPTURE_PREVIEW_PHOTO_STARTED", 9: "CAPTURE_PREVIEW_VIDEO_STARTED", 10: "CAPTURE_READY_PREVIEW_ON",
    ]
    public static let captureButton: [UInt64: String] = [
        0: "UNKNOWN", 1: "SHORT_PRESS_DOWN", 2: "LONG_PRESS", 3: "VERY_LONG_PRESS", 4: "VERY_VERY_LONG_PRESS",
        5: "SHORT_PRESS_UP", 6: "EXTREMELY_LONG_PRESS", 7: "VERY_VERY_LONG_PRESS_UP", 8: "DOUBLE_PRESS",
    ]
    public static let captouch: [UInt64: String] = [
        0: "UNKNOWN", 1: "SINGLE_TAP", 2: "DOUBLE_TAP", 3: "TAP_HOLD", 4: "SWIPE_BACKWARD", 5: "SWIPE_FORWARD",
        6: "SLIDE_BACKWARD", 7: "SLIDE_FORWARD", 8: "TRIPLE_TAP", 9: "PRESENSE_TOUCHED", 10: "PRESENSE_CLEAR",
        11: "PALM_TAP", 12: "PALM_HOLD",
    ]
    public static let actionButton: [UInt64: String] = [0: "UNKNOWN", 1: "SHORT_PRESS_DOWN", 2: "SHORT_PRESS_UP", 3: "LONG_PRESS_UP"]
    public static let hinge: [UInt64: String] = [0: "UNKNOWN", 1: "OPEN", 2: "CLOSED"]
    public static let storageLevel: [UInt64: String] = [0: "UNDEFINED", 1: "STABLE", 2: "LOW", 3: "ZERO"]
    public static let lockState: [UInt64: String] = [0: "NO_LOCK", 1: "LOCKED", 2: "UNLOCKED"]
    public static let thermalHealth: [UInt64: String] = [0: "UNKNOWN", 1: "NORMAL", 2: "LIGHT", 3: "MODERATE", 4: "SEVERE", 5: "CRITICAL", 6: "SHUTDOWN"]
    public static let volumeStream: [UInt64: String] = [0: "UNKNOWN", 1: "MEDIA", 2: "TELEPHONY", 3: "CURRENT"]
    public static let assistantAttention: [UInt64: String] = [
        0: "UNKNOWN", 1: "IDLE", 2: "WAKE", 3: "LISTENING", 4: "PROCESSING", 5: "RESPONDING", 6: "LONG_RUNNING_SESSION_ACTIVATED",
    ]
    public static let peakPower: [UInt64: String] = [0: "UNKNOWN", 1: "NORMAL", 2: "THROTTLE_LEVEL_1", 3: "THROTTLE_LEVEL_2", 4: "THROTTLE_LEVEL_3", 5: "SHUTDOWN"]
    public static let ancsState: [UInt64: String] = [0: "UNKNOWN", 1: "READY_TO_CONNECT", 2: "CONNECTING", 3: "CONNECTED", 4: "DISCONNECTED"]
    public static let btcState: [UInt64: String] = [0: "UNKNOWN", 1: "CONNECTED", 2: "DISCONNECTED"]
    public static let callState: [UInt64: String] = [
        0: "UNKNOWN", 1: "TERMINATED", 2: "DIALING", 3: "ACTIVE", 4: "INCOMING", 5: "WAITING", 6: "ALERTING", 7: "HELD",
        8: "HELD_BY_RESPONSE_AND_HOLD",
    ]
    public static let callingState: [UInt64: String] = [
        0: "UNKNOWN", 1: "IDLE", 2: "ACTIVE", 3: "RINGING", 4: "VIDEO_ACTIVE", 5: "PTT_ACTIVE", 6: "DIALING", 7: "ACTIVE_3P",
    ]
    public static let callPlatform: [UInt64: String] = [0: "UNKNOWN", 1: "NATIVE", 2: "MESSENGER", 3: "INSTAGRAM", 4: "WHATSAPP"]
    public static let appState: [UInt64: String] = [0: "UNKNOWN", 1: "ACTIVE", 2: "INACTIVE", 3: "PAUSED"]
    public static let waterDetect: [UInt64: String] = [0: "UNKNOWN", 1: "DETECTED", 2: "NOT_DETECTED"]
    public static let cameraSensing: [UInt64: String] = [0: "UNKNOWN", 1: "OFF", 2: "SENSING", 3: "PAUSED", 4: "UNMOUNTED", 5: "BUSY", 6: "ACS_ERROR"]
    public static let odcState: [UInt64: String] = [0: "UNKNOWN", 1: "STARTING", 2: "STARTED", 3: "STOPPING", 4: "STOPPED", 5: "FAILED"]
    public static let casePlatform: [UInt64: String] = [
        0: "UNKNOWN", 1: "CABO", 2: "LYNX", 3: "BORA", 4: "RIO", 5: "BORACAY", 6: "BATAN", 7: "ORCA", 8: "TIGERFISH",
        9: "BRANZINO", 10: "BORA_ULC", 11: "ORCA_ULC", 16: "SHALE", 17: "FUJI", 18: "RAPTOR", 19: "TOPAZ",
        20: "BLUEFIN", 21: "BIGEYE", 253: "COCOS",
    ]

    public static func name(_ table: [UInt64: String], _ value: UInt64) -> String { table[value] ?? "UNKNOWN_\(value)" }
}

/// One line of the flat, human-readable reading. `key` is stable; `label` and `value` are English for display.
public struct StatusField: Encodable, Equatable {
    public let key: String
    public let label: String
    public let value: String

    public init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }
}

/// Everything known about the glasses: svc28's DeviceState (snapshot with every later push merged in) and svc100's
/// build info. Every field is optional: nil means the glasses have not said.
public struct GlassesStatus: Encodable {
    public struct Battery: Encodable, Equatable {
        public var percent: Int
        public var charging: Bool
        public var chargeState: String
        public var health: String
        public var volts: Double
        public var temperatureC: Double
    }

    /// The glasses' last reading of their case, through the charging pins.
    public struct CaseBattery: Encodable, Equatable {
        /// False when the reading is empty (level -1 after a long time out of the case).
        public var known: Bool
        public var present: Bool
        /// Signed: -1 when unknown. In `scale` units (100 percent or 4 bars).
        public var level: Int
        public var scale: Int
        /// Only when known and the scale is 100.
        public var percent: Int?
        public var charging: Bool
        public var health: String
        public var serial: String?
        public var firmware: String?
        public var platform: String
        public var incompatibleCharger: Bool
        public var liquidDetected: Bool
    }

    public struct Hardware: Encodable, Equatable {
        public var dspOk, imuOk, mcuOk, microphoneOk, speakerOk, captouchOk: Bool
    }

    public struct Led: Encodable, Equatable {
        public var ledOk, privacyLedOk, ledActive, privacyLedActive: Bool
    }

    public struct Tampering: Encodable, Equatable {
        public var tampered: Bool
        public var lux: Int
        public var indoor: Bool
    }

    public struct Thermal: Encodable, Equatable {
        public var health: String
        /// As pushed: the unit is unknown (it reads 0 in every push seen), so it is not converted.
        public var temperatureRaw: Int
        public var throttling: Bool
        public var throttleReason: Int
    }

    public struct Bluetooth: Encodable, Equatable {
        public var ancs, map, pbap, btc: String
    }

    public struct Volume: Encodable, Equatable {
        /// No known unit.
        public var level: Int
        public var percent: Int
        public var stream: String
    }

    public struct Call: Encodable, Equatable {
        public var state, callingState, platform: String
        public var startTimeMs: Int64
    }

    /// One app entry: in `peakPower` (state from `PEAK_POWER`) and `apps` (state from `APP_STATE`).
    public struct AppState: Encodable, Equatable {
        public var appId: Int64
        public var state: String
    }

    // Headline readings, flat for the UI.
    public var batteryPercent: Int?
    public var charging: Bool?
    public var caseBatteryPercent: Int?
    public var caseCharging: Bool?
    public var casePresent: Bool?
    /// Mount state `DON`.
    public var worn: Bool?
    /// Hinge `OPEN`: the arms are unfolded. The protocol has no case-lid state; `CLOSED` is also read while charging in the case.
    public var armsOpen: Bool?
    /// Battery temperature in degrees C.
    public var temperatureC: Double?
    /// Camera state `CAPTURE_VIDEO_STARTED`.
    public var recording: Bool?
    public var storageFreeMb: Int?
    public var storageTotalMb: Int?

    // svc28 DeviceState, field by field.
    public var battery: Battery?
    public var caseBattery: CaseBattery?
    public var camera: String?
    public var captureButton: String?
    public var captouch: String?
    public var hinge: String?
    public var hardware: Hardware?
    public var led: Led?
    public var mount: String?
    public var deepSleepPending: Bool?
    public var inDeepSleep: Bool?
    public var storageLevel: String?
    public var tampering: Tampering?
    public var thermal: Thermal?
    public var sessionVerified: Bool?
    public var peakPower: [AppState]?
    public var audioActive: Bool?
    public var streamingActive: Bool?
    public var hotCar: Bool?
    public var bluetooth: Bluetooth?
    public var interruptedApp: Int64?
    public var registeredApps: [Int64]?
    public var volume: Volume?
    public var lockState: String?
    public var apps: [AppState]?
    public var call: Call?
    public var actionButton: String?
    public var assistantAttention: String?
    public var waterDetect: String?
    public var cameraSensing: String?
    public var odc: String?
    public var overhead: Bool?
    public var interactionKey: String?

    // svc100 build info.
    public var build: String?
    /// The number before `:user` in the build fingerprint.
    public var firmwareVersion: String?
    public var serial: String?
    public var model: String?
    public var deviceUuid: String?
    public var bluetoothAddress: String?

    /// The svc28 type of the last DeviceState message folded in, and its kind name.
    public var lastMessageType: Int?
    public var lastKind: String?

    /// Everything above that is known, as display lines.
    public var fields: [StatusField] = []

    public init() {}

    /// Decode one DeviceState payload (a snapshot or a partial push), keeping only what it carries.
    public static func decode(_ payload: [UInt8], info: DeviceInfo? = nil) -> GlassesStatus {
        decode(fields: Wire.parseLenient(payload), info: info)
    }

    static func decode(fields top: Wire.Fields, info: DeviceInfo?) -> GlassesStatus {
        typealias E = StatusEnums
        func name(_ t: [UInt64: String], _ v: UInt64) -> String { E.name(t, v) }
        func bool(_ v: UInt64) -> Bool { v != 0 }
        func int(_ v: UInt64) -> Int { Int(truncatingIfNeeded: v) }
        func sub(_ n: Int) -> Wire.Fields { Wire.parseLenient(top.bytes(n)) }

        var s = GlassesStatus()
        if top.has(1) {
            let b = sub(1)
            let charge = name(E.chargeState, b.varint(2))
            s.battery = Battery(
                percent: int(b.varint(3)), charging: E.chargingStates.contains(charge), chargeState: charge,
                health: name(E.batteryHealth, b.varint(1)),
                volts: Double(b.varint(5)) / 1000, temperatureC: Double(b.varint(4)) / 1000
            )
        }
        if top.has(2) { s.caseBattery = decodeCase(sub(2)) }
        if top.has(3) { s.camera = name(E.camera, top.varint(3)) }
        if top.has(4) { s.captureButton = name(E.captureButton, top.varint(4)) }
        if top.has(5) { s.captouch = name(E.captouch, top.varint(5)) }
        if top.has(6) { s.hinge = name(E.hinge, top.varint(6)) }
        if top.has(7) {
            let h = sub(7)
            s.hardware = Hardware(dspOk: bool(h.varint(1)), imuOk: bool(h.varint(2)), mcuOk: bool(h.varint(3)),
                                  microphoneOk: bool(h.varint(4)), speakerOk: bool(h.varint(5)), captouchOk: bool(h.varint(6)))
        }
        if top.has(8) {
            let l = sub(8)
            s.led = Led(ledOk: bool(l.varint(1)), privacyLedOk: bool(l.varint(2)), ledActive: bool(l.varint(3)), privacyLedActive: bool(l.varint(4)))
        }
        if top.has(9) { s.mount = name(E.mount, top.varint(9)) }
        if top.has(10) {
            let p = sub(10)
            s.deepSleepPending = bool(p.varint(1))
            s.inDeepSleep = bool(p.varint(2))
        }
        if top.has(11) { s.storageLevel = name(E.storageLevel, top.varint(11)) }
        if top.has(12) {
            let t = sub(12)
            s.tampering = Tampering(tampered: bool(t.varint(1)), lux: int(t.varint(2)), indoor: bool(t.varint(3)))
        }
        if top.has(13) {
            let t = sub(13)
            s.thermal = Thermal(health: name(E.thermalHealth, t.varint(1)), temperatureRaw: int(t.varint(2)),
                                throttling: bool(t.varint(3)), throttleReason: int(t.varint(4)))
        }
        if top.has(14) { s.sessionVerified = bool(top.varint(14)) }
        if top.has(15) {
            s.peakPower = top.repeatedBytes(15).map {
                let e = Wire.parseLenient($0)
                return AppState(appId: Int64(bitPattern: e.varint(1)), state: name(E.peakPower, e.varint(2)))
            }
        }
        if top.has(16) { s.audioActive = bool(top.varint(16)) }
        if top.has(17) { s.streamingActive = bool(top.varint(17)) }
        if top.has(18) { s.hotCar = bool(top.varint(18)) }
        if top.has(19) {
            let b = sub(19)
            s.bluetooth = Bluetooth(ancs: name(E.ancsState, b.varint(1)), map: name(E.ancsState, b.varint(2)),
                                    pbap: name(E.ancsState, b.varint(3)), btc: name(E.btcState, b.varint(4)))
        }
        if top.has(20) { s.interruptedApp = Int64(bitPattern: sub(20).varint(1)) }
        if top.has(21) {
            let st = sub(21)
            s.storageFreeMb = int(st.varint(1))
            s.storageTotalMb = int(st.varint(2))
        }
        if top.has(22) { s.registeredApps = top.repeatedBytes(22).map { Int64(bitPattern: Wire.parseLenient($0).varint(1)) } }
        if top.has(25) {
            let v = sub(25)
            s.volume = Volume(level: int(v.varint(1)), percent: int(v.varint(3)), stream: name(E.volumeStream, v.varint(2)))
        }
        if top.has(26) { s.lockState = name(E.lockState, top.varint(26)) }
        if top.has(27) {
            s.apps = top.repeatedBytes(27).map {
                let e = Wire.parseLenient($0)
                return AppState(appId: Int64(bitPattern: e.varint(1)), state: name(E.appState, e.varint(2)))
            }
        }
        if top.has(28) {
            let c = sub(28)
            s.call = Call(state: name(E.callState, c.varint(1)), callingState: name(E.callingState, c.varint(2)),
                          platform: name(E.callPlatform, c.varint(3)), startTimeMs: Int64(bitPattern: c.varint(4)))
        }
        if top.has(29) { s.actionButton = name(E.actionButton, top.varint(29)) }
        if top.has(31) { s.assistantAttention = name(E.assistantAttention, sub(31).varint(1)) }
        if top.has(35) { s.waterDetect = name(E.waterDetect, top.varint(35)) }
        if top.has(36) { s.cameraSensing = name(E.cameraSensing, top.varint(36)) }
        if top.has(37) { s.odc = name(E.odcState, top.varint(37)) }
        if top.has(39) { s.overhead = bool(top.varint(39)) }
        if top.has(10000) { s.interactionKey = top.string(10000) }

        s.batteryPercent = s.battery?.percent
        s.charging = s.battery?.charging
        s.temperatureC = s.battery?.temperatureC
        s.caseBatteryPercent = s.caseBattery?.percent
        s.caseCharging = s.caseBattery?.charging
        s.casePresent = s.caseBattery?.present
        s.worn = s.mount.map { $0 == "DON" }
        s.armsOpen = s.hinge.flatMap { $0 == "OPEN" ? true : $0 == "CLOSED" ? false : nil }
        s.recording = s.camera.map { $0 == "CAPTURE_VIDEO_STARTED" }

        if let info {
            s.build = info.build.isEmpty ? nil : info.build
            s.firmwareVersion = BuildFingerprint.firmwareVersion(info.build)
            s.serial = info.serial.isEmpty ? nil : info.serial
            s.model = info.model.isEmpty ? nil : info.model
            s.deviceUuid = BuildFingerprint.isUuidShaped(info.deviceUuid) ? info.deviceUuid : nil
            s.bluetoothAddress = info.bluetoothAddress.isEmpty ? nil : info.bluetoothAddress
        }
        s.fields = s.displayFields()
        return s
    }

    private static func decodeCase(_ c: Wire.Fields) -> CaseBattery {
        // Signed 32-bit: -1 arrives as 0xFFFFFFFF (or sign-extended to 64 bits).
        let level = Int(Int32(truncatingIfNeeded: c.varint(3)))
        // The app's default when the field is absent.
        let scale = c.varint(7) != 0 ? Int(truncatingIfNeeded: c.varint(7)) : 4
        let known = level >= 0 && level <= scale
        let firmware = c.string(5)
        let serial = c.string(4)
        return CaseBattery(
            known: known, present: c.varint(8) != 0, level: level, scale: scale,
            percent: known && scale == 100 ? level : nil,
            charging: c.varint(2) != 0, health: StatusEnums.name(StatusEnums.batteryHealth, c.varint(1)),
            serial: serial.isEmpty ? nil : serial,
            firmware: firmware.isEmpty || firmware == "0.0.0" ? nil : firmware,
            platform: StatusEnums.name(StatusEnums.casePlatform, c.varint(9)),
            incompatibleCharger: c.varint(6) != 0, liquidDetected: c.varint(10) != 0
        )
    }

    // MARK: display

    /// "CAPTURE_VIDEO_STARTED" -> "Capture video started".
    static func humanize(_ raw: String) -> String {
        let words = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func displayFields() -> [StatusField] {
        var out: [StatusField] = []
        func add(_ key: String, _ label: String, _ value: String?) {
            if let value { out.append(StatusField(key: key, label: label, value: value)) }
        }
        func yes(_ b: Bool?) -> String? { b.map { $0 ? "Yes" : "No" } }
        func en(_ s: String?) -> String? { s.map(GlassesStatus.humanize) }
        func appList(_ list: [AppState]?) -> String? {
            list.map { $0.isEmpty ? "None" : $0.map { "\($0.appId): \(GlassesStatus.humanize($0.state))" }.joined(separator: ", ") }
        }

        add("model", "Model", model)
        add("serial", "Serial number", serial)
        add("firmwareVersion", "Firmware version", firmwareVersion)
        add("build", "Build", build)
        add("deviceUuid", "Device UUID", deviceUuid)
        add("bluetoothAddress", "Bluetooth address", bluetoothAddress)

        if let b = battery {
            add("batteryPercent", "Battery", "\(b.percent)%")
            add("charging", "Charging", yes(b.charging))
            add("chargeState", "Charge state", en(b.chargeState))
            add("batteryHealth", "Battery health", en(b.health))
            add("batteryVoltage", "Battery voltage", String(format: "%.2f V", b.volts))
            add("batteryTemperature", "Battery temperature", String(format: "%.1f °C", b.temperatureC))
        }
        if let c = caseBattery {
            add("casePresent", "Case present", yes(c.present))
            let level: String
            if !c.known { level = "Unknown" } else if c.scale == 100 { level = "\(c.level)%" } else { level = "\(c.level)/\(c.scale) bars" }
            add("caseBattery", "Case battery", level)
            add("caseCharging", "Case charging", yes(c.charging))
            add("caseHealth", "Case battery health", en(c.health))
            add("caseSerial", "Case serial number", c.serial)
            add("caseFirmware", "Case firmware", c.firmware)
            add("casePlatform", "Case model", en(c.platform))
            add("caseIncompatibleCharger", "Incompatible charger", yes(c.incompatibleCharger))
            add("caseLiquidDetected", "Liquid detected in case", yes(c.liquidDetected))
        }
        add("worn", "Worn", yes(worn))
        add("mount", "Mount state", en(mount))
        add("hinge", "Arms", hinge.map { $0 == "OPEN" ? "Open" : $0 == "CLOSED" ? "Folded" : GlassesStatus.humanize($0) })
        add("overhead", "Overhead", yes(overhead))
        add("camera", "Camera", en(camera))
        add("recording", "Recording", yes(recording))
        add("cameraSensing", "Camera sensing", en(cameraSensing))
        if let free = storageFreeMb { add("storageFree", "Storage free", "\(free) MB") }
        if let total = storageTotalMb { add("storageTotal", "Storage total", "\(total) MB") }
        add("storageLevel", "Storage level", en(storageLevel))
        if let t = thermal {
            add("thermalHealth", "Thermal state", en(t.health))
            add("thermalThrottling", "Thermal throttling", yes(t.throttling))
            add("thermalThrottleReason", "Throttle reason", "\(t.throttleReason)")
            add("thermalTemperature", "Thermal temperature (raw)", "\(t.temperatureRaw)")
        }
        add("peakPower", "Peak power", appList(peakPower))
        add("hotCar", "Hot car", yes(hotCar))
        add("waterDetect", "Water", en(waterDetect))
        add("deepSleepPending", "Deep sleep pending", yes(deepSleepPending))
        add("inDeepSleep", "In deep sleep", yes(inDeepSleep))
        add("lockState", "Lock", en(lockState))
        add("sessionVerified", "Session verified", yes(sessionVerified))
        if let v = volume {
            add("volume", "Volume", "\(v.percent)%")
            add("volumeLevel", "Volume level", "\(v.level)")
            add("volumeStream", "Volume stream", en(v.stream))
        }
        add("audioActive", "Audio active", yes(audioActive))
        add("streamingActive", "Streaming active", yes(streamingActive))
        add("assistantAttention", "Assistant", en(assistantAttention))
        if let c = call {
            add("callState", "Call", en(c.state))
            add("callingState", "Calling state", en(c.callingState))
            add("callPlatform", "Call app", en(c.platform))
            if c.startTimeMs > 0 {
                add("callStart", "Call started", ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(c.startTimeMs) / 1000)))
            }
        }
        if let b = bluetooth {
            add("bluetoothAncs", "Notifications (ANCS)", en(b.ancs))
            add("bluetoothMap", "Messages (MAP)", en(b.map))
            add("bluetoothPbap", "Contacts (PBAP)", en(b.pbap))
            add("bluetoothBtc", "Bluetooth Classic", en(b.btc))
        }
        add("captureButton", "Capture button", en(captureButton))
        add("actionButton", "Action button", en(actionButton))
        add("captouch", "Touch pad", en(captouch))
        if let h = hardware {
            add("dspOk", "DSP OK", yes(h.dspOk))
            add("imuOk", "IMU OK", yes(h.imuOk))
            add("mcuOk", "MCU OK", yes(h.mcuOk))
            add("microphoneOk", "Microphone OK", yes(h.microphoneOk))
            add("speakerOk", "Speaker OK", yes(h.speakerOk))
            add("captouchOk", "Touch pad OK", yes(h.captouchOk))
        }
        if let l = led {
            add("ledOk", "LED OK", yes(l.ledOk))
            add("privacyLedOk", "Privacy LED OK", yes(l.privacyLedOk))
            add("ledActive", "LED active", yes(l.ledActive))
            add("privacyLedActive", "Privacy LED active", yes(l.privacyLedActive))
        }
        if let t = tampering {
            add("tampered", "Tampered", yes(t.tampered))
            add("lux", "Ambient light", "\(t.lux) lux")
            add("indoor", "Indoors", yes(t.indoor))
        }
        add("odc", "On-device capture", en(odc))
        add("apps", "Apps", appList(apps))
        add("registeredApps", "Registered apps", registeredApps.map { $0.isEmpty ? "None" : $0.map(String.init).joined(separator: ", ") })
        add("interruptedApp", "Interrupted app", interruptedApp.map(String.init))
        return out
    }
}

/// The svc100 build fingerprint: `Meta/<product>/<device>:<release>/<build id>/<firmware version>:user/release-keys`.
public enum BuildFingerprint {
    /// The number before `:user`, or nil when the fingerprint does not have that shape.
    public static func firmwareVersion(_ build: String) -> String? {
        let parts = build.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, let version = parts[4].split(separator: ":").first, !version.isEmpty else { return nil }
        return String(version)
    }

    /// 36 characters in the 8-4-4-4-12 shape, as `DeviceInfo.kt` checks before trusting field 4.
    public static func isUuidShaped(_ text: String) -> Bool {
        text.count == 36 && text.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [8, 4, 4, 4, 12]
    }
}

/// The merged state of one session: every svc28 DeviceState message folds in by top-level field (a push replaces
/// only the fields it carries, as `mergeDeviceState` does), plus the svc100 answer. Feeds watchers and one-shot waits.
public final class StatusHub {
    private let lock = NSLock()
    private var raw = Wire.Fields()
    private var info: DeviceInfo?
    private var lastType: Int?
    private var current = GlassesStatus()
    private var watchers: [UUID: (GlassesStatus) -> Void] = [:]
    private var waiters: [Waiter] = []
    private var _subscribed = false
    /// A subscribe has gone out on this session.
    var subscribed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _subscribed }
        set { lock.lock(); _subscribed = newValue; lock.unlock() }
    }

    final class Waiter {
        let match: (Int, Wire.Fields, GlassesStatus) -> Bool
        private let lock = NSLock()
        private var done = false
        private var result: GlassesStatus?
        private var continuation: CheckedContinuation<GlassesStatus?, Never>?

        init(_ match: @escaping (Int, Wire.Fields, GlassesStatus) -> Bool) { self.match = match }

        /// The first delivery wins; nil means cancelled.
        func deliver(_ s: GlassesStatus?) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            result = s
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: s)
        }

        func wait() async -> GlassesStatus? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    lock.lock()
                    if done { let r = result; lock.unlock(); c.resume(returning: r) } else { continuation = c; lock.unlock() }
                }
            } onCancel: {
                deliver(nil)
            }
        }
    }

    public init() {}

    public var status: GlassesStatus {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Fold one svc28 message in. Returns the merged state, or nil when the type carries no DeviceState.
    @discardableResult
    public func ingest(messageType: Int, payload: [UInt8]) -> GlassesStatus? {
        guard StatusMsg.isDeviceState(messageType) else { return nil }
        let update = Wire.parseLenient(payload)
        lock.lock()
        for (field, values) in update.byField { raw.replace(field, values) }
        lastType = messageType
        let merged = rebuildLocked()
        let ready = waiters.filter { $0.match(messageType, update, merged) }
        waiters.removeAll { w in ready.contains { $0 === w } }
        let notify = Array(watchers.values)
        lock.unlock()
        for w in ready { w.deliver(merged) }
        for n in notify { n(merged) }
        return merged
    }

    @discardableResult
    public func ingest(info: DeviceInfo) -> GlassesStatus {
        lock.lock()
        self.info = info
        let merged = rebuildLocked()
        let notify = Array(watchers.values)
        lock.unlock()
        for n in notify { n(merged) }
        return merged
    }

    var hasInfo: Bool { lock.lock(); defer { lock.unlock() }; return info != nil }

    private func rebuildLocked() -> GlassesStatus {
        var s = GlassesStatus.decode(fields: raw, info: info)
        s.lastMessageType = lastType
        s.lastKind = lastType.flatMap { StatusMsg.deviceStateTypes[$0] }
        current = s
        return s
    }

    func addWatcher(_ f: @escaping (GlassesStatus) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); watchers[id] = f; lock.unlock()
        return id
    }

    func removeWatcher(_ id: UUID) {
        lock.lock(); watchers[id] = nil; lock.unlock()
    }

    /// Register BEFORE sending what provokes the answer. `match` sees the type, the fields of that one message and
    /// the merged state.
    func expect(_ match: @escaping (Int, Wire.Fields, GlassesStatus) -> Bool) -> Waiter {
        let w = Waiter(match)
        lock.lock(); waiters.append(w); lock.unlock()
        return w
    }

    func cancel(_ w: Waiter) {
        lock.lock(); waiters.removeAll { $0 === w }; lock.unlock()
    }

    /// The state that satisfied `w`, or nil after `timeout`.
    func collect(_ w: Waiter, timeout: TimeInterval) async throws -> GlassesStatus? {
        let r = try await withDeadline(timeout) { await w.wait() } ?? nil
        if r == nil { cancel(w) }
        return r
    }
}

extension Wire.Fields {
    mutating func replace(_ field: Int, _ values: [Value]) {
        var copy = Wire.Fields()
        for (f, vs) in byField where f != field { for v in vs { copy.add(f, v) } }
        for v in values { copy.add(field, v) }
        self = copy
    }
}

private let statusHubLock = NSLock()
private var statusHubKey: UInt8 = 0

extension GlassesSession {
    /// This session's merged svc28 state. Its svc28 responder is installed by `readStatus`, `watchStatus`,
    /// `subscribeStatus` and the shutter.
    public var statusHub: StatusHub {
        statusHubLock.lock(); defer { statusHubLock.unlock() }
        if let hub = objc_getAssociatedObject(self, &statusHubKey) as? StatusHub { return hub }
        let hub = StatusHub()
        objc_setAssociatedObject(self, &statusHubKey, hub, .OBJC_ASSOCIATION_RETAIN)
        return hub
    }

    /// The one svc28 responder: everything on service 28 goes through the hub. Idempotent.
    func installStatusResponder() -> StatusHub {
        let hub = statusHub
        addResponder(ServiceIds.status) { message, _ in
            hub.ingest(messageType: message.info.messageType, payload: message.payload)
        }
        return hub
    }

    /// Send the svc28 subscribe (type 1000) on the session's svc28 channel. The first one starts the pushes; each
    /// later one brings a fresh 2005 snapshot without a second push stream.
    public func subscribeStatus() async throws {
        let hub = installStatusResponder()
        try await send(service: ServiceIds.status, type: StatusMsg.subscribe,
                       payload: StatusMsg.subscribePayload(interactionKey: UUID().uuidString.lowercased()))
        hub.subscribed = true
    }

    /// Subscribe (or re-subscribe) on svc28 and return the 2005 snapshot merged with every push so far. Also asks
    /// svc100 for the build info the first time, unless `includeBuildInfo` is false; its failure is not fatal.
    public func readStatus(timeout: TimeInterval = 10, includeBuildInfo: Bool = true) async throws -> GlassesStatus {
        let hub = installStatusResponder()
        let w = hub.expect { type, _, _ in type == StatusMsg.deviceState }
        do { try await subscribeStatus() } catch { hub.cancel(w); throw error }
        guard try await hub.collect(w, timeout: timeout) != nil else {
            throw SessionError("svc28 sent no device state in \(Int(timeout)) s")
        }
        if includeBuildInfo, !hub.hasInfo, let info = try? await peerDeviceInfo(timeout: min(timeout, 5)) {
            hub.ingest(info: info)
        }
        return hub.status
    }

    /// Call `onUpdate` with the merged state on every svc28 DeviceState message (and on the svc100 answer). Installs
    /// the svc28 responder only: the pushes start with `readStatus` or `subscribeStatus`.
    @discardableResult
    public func watchStatus(_ onUpdate: @escaping (GlassesStatus) -> Void) -> UUID {
        installStatusResponder().addWatcher(onUpdate)
    }

    public func unwatchStatus(_ id: UUID) {
        statusHub.removeWatcher(id)
    }
}

// MARK: - Clock (svc22)

/// svc22 DeviceInfoRequest: the phone sets the glasses' clock and time zone, as the Meta app does on every connect.
/// Every capture is stamped with that clock.
public enum ClockSync {
    public static let deviceInfoRequest = 1

    /// {1: Timestamp {1: seconds, 2: nanos}, 2: time zone id, 3: request uuid (16 bytes)}.
    public static func payload(nowMillis: Int64, zone: String, requestId: [UInt8]) -> [UInt8] {
        let (seconds, millis) = floorDivMod(nowMillis, 1000)
        let timestamp = Wire.fieldVarint(1, UInt64(bitPattern: seconds)) + Wire.fieldVarint(2, UInt64(bitPattern: millis * 1_000_000))
        return Wire.fieldBytes(1, timestamp) + Wire.fieldString(2, zone) + Wire.fieldBytes(3, requestId)
    }

    static func floorDivMod(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        var q = a / b, r = a % b
        if r < 0 { q -= 1; r += b }
        return (q, r)
    }
}

extension GlassesSession {
    /// Set the glasses' clock and time zone to this Mac's. Fire and forget on a new svc22 channel, as `Clock.kt` does.
    public func syncClock(now: Date = Date(), timeZone: TimeZone = .current) async throws {
        guard let mux = connection else { throw SessionError("not connected") }
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let u = UUID().uuid
        let requestId = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        let payload = ClockSync.payload(nowMillis: millis, zone: timeZone.identifier, requestId: requestId)
        let channel = mux.openChannel(ServiceIds.deviceInfo)
        try await mux.send(channel: channel, payload: payload, messageType: ClockSync.deviceInfoRequest, serviceId: ServiceIds.deviceInfo)
    }
}
