import Foundation
import VisorKit

/// Status, shutter and clock (svc28, svc22), and the glasses settings, wired into the controller and routes.
func installAddOns(_ c: Controller, _ r: Routes) {
    var features: [String: AnyEncodable] = ["status": true, "shutter": true, "clock": true, "settings": false]
    c.setExtra("shutterActions", AnyEncodable([
        ["action": AnyEncodable("photo"), "label": AnyEncodable("Prendre une photo"), "primary": AnyEncodable(true)],
        ["action": AnyEncodable("video"), "label": AnyEncodable("Démarrer une vidéo")],
        ["action": AnyEncodable("hyperlapse"), "label": AnyEncodable("Démarrer un hyperlapse")],
        ["action": AnyEncodable("stop"), "label": AnyEncodable("Arrêter la vidéo")],
    ]))

    func publish(_ s: GlassesStatus) {
        c.setExtra("status", AnyEncodable(StatusDTO(at: Date(), fields: s.fields, batteryPercent: s.batteryPercent, charging: s.charging,
                                                     caseBatteryPercent: s.caseBatteryPercent, worn: s.worn, recording: s.recording)))
    }

    // Each fresh session: follow the pushed state, and ask for a first snapshot.
    c.onSession.append { s in
        s.watchStatus { publish($0) }
        do { publish(try await s.readStatus(timeout: 8)) } catch { c.log("État des lunettes non lu : \(error)", "debug") }
    }

    r.extra["POST /api/status/read"] = { _ in
        c.start("status", "Lecture de l'état des lunettes") {
            let s = try await c.ensureSession()
            c.setDetail("Lecture de l'état…")
            publish(try await s.readStatus())
        }
    }
    r.extra["POST /api/clock"] = { _ in
        c.start("clock", "Mise à l'heure des lunettes") {
            let s = try await c.ensureSession()
            try await s.syncClock()
            c.log("Heure envoyée aux lunettes (\(TimeZone.current.identifier))", "ok")
        }
    }
    r.extra["POST /api/shutter"] = { req in
        struct A: Decodable { let action: String }
        guard let a = req.json(A.self) else { return .error(400, "action manquante") }
        let labels = ["photo": "Photo", "video": "Démarrage d'une vidéo", "hyperlapse": "Démarrage d'un hyperlapse", "stop": "Arrêt de la vidéo"]
        guard let label = labels[a.action] else { return .error(400, "action inconnue") }
        return c.start("shutter", label) {
            let s = try await c.ensureSession()
            switch a.action {
            case "photo": try await s.takePhoto()
            case "video": try await s.startVideo(.video)
            case "hyperlapse": try await s.startVideo(.hyperlapse)
            default: try await s.stopVideo()
            }
            c.log("\(label) : les lunettes ont confirmé", "ok")
        }
    }

    installSettings(c, r, &features)
    c.setExtra("features", AnyEncodable(features))
}

struct StatusDTO: Encodable {
    let at: Date
    let fields: [StatusField]
    let batteryPercent: Int?
    let charging: Bool?
    let caseBatteryPercent: Int?
    let worn: Bool?
    let recording: Bool?
}

/// The glasses settings: svc33 to read, svc31 (or svc33) to write. Only catalogue keys, checked before sending.
func installSettings(_ c: Controller, _ r: Routes, _ features: inout [String: AnyEncodable]) {
    features["settings"] = true
    let lock = NSLock()
    var values: [String: SettingRaw] = [:]
    var readAt: Date?
    func publish() {
        let snapshot = lock.withLock { (values, readAt) }
        c.setExtra("settings", AnyEncodable(SettingsDTO(values: snapshot.0, at: snapshot.1)))
    }

    r.extra["GET /api/settings/catalog"] = { _ in .json(SettingsCatalog.all) }
    r.extra["POST /api/settings/read"] = { _ in
        c.start("settings-read", "Lecture des réglages des lunettes") {
            let s = try await c.ensureSession()
            c.setDetail("Lecture des réglages (quelques secondes en Bluetooth)…")
            let read = try await s.readSettings(deviceUuid: c.deviceUuid, timeout: 10)
            lock.withLock { values = read; readAt = Date() }
            c.log("\(read.count) réglages lus", "ok")
            publish()
        }
    }
    r.extra["POST /api/settings/write"] = { req in
        struct W: Decodable { let key: String; let value: SettingRaw }
        guard let w = req.json(W.self) else { return .error(400, "réglage invalide") }
        guard let d = SettingsCatalog.descriptor(w.key), d.writable else { return .error(400, "réglage inconnu ou en lecture seule") }
        return c.start("settings-write", "Réglage « \(d.label) »") {
            let s = try await c.ensureSession()
            do {
                try await s.writeSetting(w.key, w.value, deviceUuid: c.deviceUuid, timeout: 10)
                lock.withLock { values[w.key] = w.value }
                c.log("« \(d.label) » = \(w.value)", "ok")
            } catch {
                publish()  // put the control back on the value the glasses hold
                throw error
            }
            publish()
        }
    }
}

struct SettingsDTO: Encodable {
    let values: [String: SettingRaw]
    let at: Date?
}
