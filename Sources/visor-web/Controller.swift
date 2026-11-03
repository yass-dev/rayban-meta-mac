import Foundation
import VisorKit

struct UIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct WebPrefs: Codable {
    var deleteAfterImport = false
    var keepLogs = false
    var autoPreviews = true
    var country = "FR"
    var exportDir: String?
}

struct LogLine: Encodable {
    let seq: Int
    let at: Date
    let level: String  // info, ok, warn, error, debug
    let text: String
}

struct Busy: Encodable {
    let op: String
    let label: String
    var detail: String?
    let started: Date
    var done: UInt64?
    var total: UInt64?
    var rate: Double?
    var cancellable: Bool
}

struct CaptureDTO: Encodable {
    let handle: String
    let short: String
    let type: String
    let takenAt: Date?
    let size: UInt64
    let sizeText: String
    let delivered: Bool
    let onMac: Bool
    let macFiles: [String]
    let hasPreview: Bool
    let landscape: Bool
}

/// Everything the web UI shows, and every action it can ask for. One operation at a time; the Bluetooth
/// session stays open between operations while the glasses keep it.
final class Controller {
    let store = Store()
    let library: Library
    let previewsDir: URL
    let caches: URL
    private(set) var prefs: WebPrefs
    let lock = NSRecursiveLock()

    enum Conn: String, Encodable { case disconnected, connecting, connected }
    private(set) var conn: Conn = .disconnected
    private var connError: String?
    private(set) var session: GlassesSession?
    /// The session being opened, so that Cancel can close it mid-connect.
    private var connecting: GlassesSession?
    private var device: DeviceInfo?
    private var captures: [Capture] = []
    private var capturesAt: Date?
    private var busy: Busy?
    private var lastResult: (ok: Bool, text: String, at: Date)?
    private var offline = false
    private var loginCheck: (ok: Bool, at: Date, detail: String)?
    private var task: Task<Void, Never>?
    private var logs: [LogLine] = []
    private var logSeq = 0
    private var clients: [EventClient] = []
    private var statePending = false
    /// Extra state the protocol add-ons (status, settings) publish, already encoded.
    var extras: [String: AnyEncodable] = [:]
    /// Hooks the add-ons install: called with each fresh session.
    var onSession: [(GlassesSession) async -> Void] = []

    init() {
        caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("visor-mac", isDirectory: true)
        previewsDir = caches.appendingPathComponent("previews", isDirectory: true)
        library = Library(caches: caches)
        prefs = store.load(WebPrefs.self, name: "web_prefs.json") ?? WebPrefs()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.broadcast("ping", Data("{}".utf8)) }
    }

    var exportDir: URL {
        prefs.exportDir?.nilIfBlank.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? Store.defaultExportDirectory
    }

    // MARK: events

    func addClient(_ c: EventClient) {
        let recent = lock.withLock { () -> [LogLine] in clients.removeAll { !$0.alive }; clients.append(c); return Array(logs.suffix(300)) }
        c.send("state", encode(state()))
        c.send("logs", encode(recent))
    }

    func broadcast(_ event: String, _ data: Data) {
        let all = lock.withLock { clients.removeAll { !$0.alive }; return clients }
        for c in all { c.send(event, data) }
    }

    /// At most four state pushes a second.
    func pushState() {
        let go = lock.withLock { () -> Bool in if statePending { return false }; statePending = true; return true }
        guard go else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.statePending = false }
            self.broadcast("state", self.encode(self.state()))
        }
    }

    func log(_ text: String, _ level: String = "info") {
        let line = lock.withLock { () -> LogLine in
            logSeq += 1
            let l = LogLine(seq: logSeq, at: Date(), level: level, text: text)
            logs.append(l)
            if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
            return l
        }
        if level != "debug" {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            print("[\(f.string(from: line.at))] \(text)")
        }
        broadcast("log", encode(line))
    }

    func logsSnapshot() -> [LogLine] { lock.withLock { logs } }

    func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(v)) ?? Data("null".utf8)
    }

    // MARK: state

    struct State: Encodable {
        let conn: String
        let connError: String?
        let busy: Busy?
        let lastResult: [String: AnyEncodable]?
        let offline: Bool
        let owner: Store.Bundle?
        let ownerKey: Bool
        let login: [String: AnyEncodable]
        let device: [String: String]?
        let captures: [CaptureDTO]
        let capturesAt: Date?
        let prefs: WebPrefs
        let exportDir: String
        let extras: [String: AnyEncodable]
    }

    /// Copies the fields under the lock, then reads the disk without it: a file access can block for as long
    /// as macOS shows its privacy prompt (the Documents folder, at first launch).
    func state() -> State {
        let snap = lock.withLock { (conn, connError, busy, lastResult, offline, loginCheck, device, captures, capturesAt, prefs, extras) }
        var login: [String: AnyEncodable] = ["tokens": AnyEncodable(store.tokens() != nil), "frla": AnyEncodable(store.frla() != nil)]
        if let c = snap.5 { login["check"] = AnyEncodable(["ok": AnyEncodable(c.ok), "at": AnyEncodable(c.at), "detail": AnyEncodable(c.detail)]) }
        let dev = snap.6.map { ["model": $0.model, "serial": $0.serial, "build": $0.build, "bluetooth": $0.bluetoothAddress, "uuid": $0.deviceUuid] }
        return State(
            conn: snap.0.rawValue, connError: snap.1, busy: snap.2,
            lastResult: snap.3.map { ["ok": AnyEncodable($0.ok), "text": AnyEncodable($0.text), "at": AnyEncodable($0.at)] },
            offline: snap.4, owner: store.bundle(), ownerKey: (try? store.ownerKey()) != nil, login: login, device: dev,
            captures: captureDTOs(snap.7), capturesAt: snap.8, prefs: snap.9, exportDir: exportDir.path, extras: snap.10
        )
    }

    /// Which captures already have their main file in the export folder: by the import index, else by file name.
    func onMac(_ list: [Capture]) -> [String: [String]] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? [])
        let index = store.imported()
        var out: [String: [String]] = [:]
        for c in list {
            if let files = index[c.handle], files.contains(where: names.contains) { out[c.handle] = files.filter(names.contains); continue }
            let tag = "_\(c.handle.prefix(6))."
            let found = names.filter { $0.hasPrefix("Visor_") && $0.contains(tag) && !$0.hasPrefix(".") }.sorted()
            if !found.isEmpty { out[c.handle] = found }
        }
        return out
    }

    private func captureDTOs(_ captures: [Capture]) -> [CaptureDTO] {
        let mac = onMac(captures)
        return captures.filter(\.isMedia).map { c in
            CaptureDTO(handle: c.handle, short: String(c.handle.prefix(8)), type: c.type.rawValue, takenAt: c.takenAt,
                       size: c.wanted.reduce(0) { $0 + $1.size }, sizeText: sizeWords(c.main?.size ?? 0),
                       delivered: c.main?.delivered ?? false, onMac: mac[c.handle] != nil, macFiles: mac[c.handle] ?? [],
                       hasPreview: FileManager.default.fileExists(atPath: previewsDir.appendingPathComponent("\(c.handle).jpg").path),
                       landscape: c.landscape)
        }
    }

    func setPrefs(_ p: WebPrefs) {
        lock.withLock { prefs = p }
        store.save(p, name: "web_prefs.json")
        pushState()
    }

    /// The glasses' device id, once svc100 has given it: saves a round trip on every settings call.
    var deviceUuid: String? { lock.withLock { device?.deviceUuid.nilIfBlank } }

    func setExtra(_ key: String, _ value: AnyEncodable?) {
        lock.withLock { extras[key] = value }
        pushState()
    }

    func setDetail(_ text: String?) {
        lock.withLock { busy?.detail = text }
        pushState()
    }

    private func setProgress(done: UInt64, total: UInt64, rate: Double?) {
        lock.withLock { busy?.done = done; busy?.total = total; busy?.rate = rate }
        pushState()
    }

    // MARK: operations

    var isBusy: Bool { lock.withLock { busy != nil } }

    /// Run `body` as the one operation in flight. Refused while another runs.
    func start(_ op: String, _ label: String, cancellable: Bool = true, _ body: @escaping () async throws -> Void) -> HTTPResponse {
        let current: String? = lock.withLock {
            if let b = busy { return b.label }
            busy = Busy(op: op, label: label, detail: nil, started: Date(), cancellable: cancellable)
            return nil
        }
        if let current { return .error(409, "Une opération est déjà en cours : \(current)") }
        log("▶ \(label)")
        pushState()
        let t = Task { [weak self] in
            guard let self else { return }
            var result: (Bool, String) = (true, "\(label) : terminé")
            do {
                try await body()
            } catch is CancellationError {
                result = (false, "\(label) : annulé")
            } catch {
                result = (false, "\(label) : \(Controller.friendly(error))")
            }
            self.log(result.1, result.0 ? "ok" : "error")
            self.lock.withLock {
                self.busy = nil
                self.task = nil
                self.lastResult = (result.0, result.1, Date())
            }
            self.pushState()
        }
        lock.withLock { if busy?.op == op { task = t } }
        return .ok()
    }

    func cancel() -> HTTPResponse {
        let (t, opening): (Task<Void, Never>?, GlassesSession?) = lock.withLock { busy?.cancellable == true ? (task, connecting) : (nil, nil) }
        guard let t else { return .error(409, "Rien à annuler") }
        t.cancel()
        opening?.close()
        log("Annulation demandée", "warn")
        return .ok()
    }

    static func friendly(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("timed out waiting for LE connection") || text.contains("did not open the link") {
            return "les lunettes ne répondent pas en Bluetooth. Sors-les de l'étui, ouvre les branches, approche-les du Mac et réessaie. Si ça ne passe toujours pas : mode appairage (bouton capture maintenu jusqu'au clignotement bleu) et Bluetooth de l'iPhone coupé."
        }
        if text.contains("Bluetooth LE powered on") { return "le Bluetooth ne répond pas : si macOS affiche une demande d'accès au Bluetooth pour « Lunettes », accepte-la puis réessaie." }
        if text.contains("Bluetooth is off") || text.contains("poweredOff") { return "le Bluetooth du Mac est coupé : rallume-le dans le Centre de contrôle." }
        if text.contains("unauthorized") { return "macOS n'autorise pas l'accès au Bluetooth : Réglages Système > Confidentialité et sécurité > Bluetooth." }
        if text.contains("could not join") { return "le Mac n'a pas pu rejoindre le Wi-Fi des lunettes (\(text))." }
        return text
    }

    // MARK: the Bluetooth session

    func ensureSession() async throws -> GlassesSession {
        if let s = lock.withLock({ conn == .connected ? session : nil }) { return s }
        guard let key = try store.ownerKey() else {
            throw UIError("ce Mac n'a pas encore de clé de propriétaire : fais l'appairage dans l'onglet Compte.")
        }
        lock.withLock { conn = .connecting; connError = nil }
        setDetail("Connexion Bluetooth aux lunettes (jusqu'à 4 min). Lunettes hors de l'étui, près du Mac.")
        let t = LeTransport(identifier: store.leIdentifier(), scanSeconds: 30)
        t.log = { [weak self] in self?.log($0, "debug") }
        let s = GlassesSession(transport: t, ownerKey: key)
        s.log = { [weak self] in self?.log($0, "debug") }
        s.onUnhandled = { [weak self] m, svc in self?.log(String(format: "svc %d type 0x%04x, %d octets (non traité)", svc, m.info.messageType, m.payload.count), "debug") }
        s.onLost = { [weak self, weak s] error in self?.lost(s, error) }
        lock.withLock { connecting = s }
        defer { lock.withLock { if connecting === s { connecting = nil } } }
        do {
            try await s.open()
            try Task.checkCancellation()
        } catch {
            s.close()
            let cancelled = Task.isCancelled
            lock.withLock { conn = .disconnected; connError = cancelled ? nil : Controller.friendly(error) }
            pushState()
            throw cancelled ? CancellationError() : error
        }
        if let id = t.peripheralIdentifier, id != store.leIdentifier() { store.saveLeIdentifier(id) }
        if let tr = s.trustResult, !tr.complete {
            log("Confiance incomplète avec les lunettes : elles risquent de refuser les commandes", "warn")
        }
        lock.withLock { session = s; conn = .connected; connError = nil }
        log("Connecté aux lunettes en Bluetooth", "ok")
        pushState()
        if let info = try? await s.peerDeviceInfo() { lock.withLock { device = info }; pushState() }
        for hook in onSession { await hook(s) }
        return s
    }

    private func lost(_ s: GlassesSession?, _ error: Error) {
        let mine = lock.withLock { () -> Bool in
            guard let s, session === s else { return false }
            session = nil
            conn = .disconnected
            connError = "connexion perdue (\(error))"
            return true
        }
        if mine { log("Connexion Bluetooth perdue", "warn"); pushState() }
    }

    /// Forget the session without closing it: an import hands it to MediaImport, which closes it itself.
    private func detach() {
        lock.withLock { session = nil; conn = .disconnected }
        pushState()
    }

    func disconnect() {
        let s = lock.withLock { () -> GlassesSession? in let s = session; session = nil; conn = .disconnected; connError = nil; return s }
        s?.close()
        log("Déconnecté")
        pushState()
    }

    // MARK: the capture list and previews

    func refresh(previews: Bool) async throws {
        let s = try await ensureSession()
        setDetail("Lecture de la liste des photos et vidéos…")
        let list = try await s.listCaptures()
        lock.withLock { captures = list; capturesAt = Date() }
        let media = list.filter(\.isMedia)
        log("\(media.count) photos et vidéos sur les lunettes")
        pushState()
        if previews { try await fetchPreviews(s, media) }
    }

    func fetchPreviews(_ s: GlassesSession, _ list: [Capture]) async throws {
        let missing = list.filter { c in c.preview != nil && !FileManager.default.fileExists(atPath: previewsDir.appendingPathComponent("\(c.handle).jpg").path) }
        guard !missing.isEmpty else { return }
        let fetcher = PreviewFetcher(session: s, directory: previewsDir)
        fetcher.log = { [weak self] in self?.log($0, "debug") }
        var n = 0
        setDetail("Aperçus : 0 / \(missing.count)")
        fetcher.onPreview = { [weak self] _, _ in
            n += 1
            self?.setDetail("Aperçus : \(n) / \(missing.count)")
        }
        let got = try await fetcher.fetchMissing(missing)
        log("\(got) aperçus reçus sur \(missing.count)", got == missing.count ? "info" : "warn")
    }

    // MARK: import

    struct ImportRequest: Decodable {
        var mode: String          // missing, new, all, selected
        var handles: [String]?
        var deleteAfter: Bool?
    }

    func importMedia(_ r: ImportRequest) async throws {
        let s = try await ensureSession()
        setDetail("Lecture de la liste…")
        let list = try await s.listCaptures()
        lock.withLock { captures = list; capturesAt = Date() }
        pushState()
        let mac = onMac(list)
        let media = list.filter(\.isMedia)
        let chosen: [Capture]
        switch r.mode {
        case "new": chosen = media.filter(\.isNew)
        case "all": chosen = media
        case "selected": let wanted = Set(r.handles ?? []); chosen = media.filter { wanted.contains($0.handle) }
        default: chosen = media.filter { mac[$0.handle] == nil }
        }
        guard !chosen.isEmpty else { log("Rien à importer : tout est déjà sur le Mac"); return }
        guard let key = try store.ownerKey() else { throw UIError("pas de clé de propriétaire") }
        let p = prefs
        var options = MediaImport.Options(output: exportDir)
        options.country = p.country
        options.keepLogs = p.keepLogs
        let total = chosen.reduce(UInt64(0)) { $0 + $1.wanted.reduce(0) { $0 + $1.size } }
        log("Import de \(chosen.count) éléments (\(sizeWords(total)))")
        var bytes: [String: UInt64] = [:]
        var firstByte: Date?
        let progressLock = NSLock()
        let job = MediaImport(bluetooth: s, ownerKey: key, captures: chosen, options: options) { [weak self] line in
            self?.log(line, "debug")
            self?.phase(from: line)
        }
        job.onProgress = { [weak self] _, asset, got, _ in
            let (done, rate): (UInt64, Double?) = progressLock.withLock {
                bytes[asset] = got
                if firstByte == nil { firstByte = Date() }
                let d = bytes.values.reduce(0, +)
                let secs = Date().timeIntervalSince(firstByte!)
                return (d, secs > 1 ? Double(d) / secs : nil)
            }
            self?.setProgress(done: done, total: total, rate: rate)
        }
        job.onSaved = { [weak self] saved in
            guard let self else { return }
            progressLock.withLock { for a in saved.capture.wanted { bytes[a.id] = a.size } }
            self.store.markImported(saved.capture.handle, files: saved.files.map(\.lastPathComponent))
            self.log("Enregistré : \(saved.files.map(\.lastPathComponent).joined(separator: ", "))", "ok")
            self.pushState()
        }
        job.onOffline = { [weak self] off in
            guard let self else { return }
            self.lock.withLock { self.offline = off }
            self.log(off ? "Le Mac passe sur le Wi-Fi des lunettes : plus d'internet pendant le transfert" : "Le Mac revient sur son Wi-Fi", off ? "warn" : "info")
            self.pushState()
        }
        setProgress(done: 0, total: total, rate: nil)
        // MediaImport takes the Bluetooth session over: the glasses drop it once Wi-Fi is up.
        detach()
        // On success MediaImport has closed it already; on an early failure it is still open.
        defer { s.close(); lock.withLock { offline = false } }
        try await job.run()
        let saved = job.saved
        log("Import : \(saved.count) sur \(chosen.count) enregistrés dans \(exportDir.path)", saved.count == chosen.count ? "ok" : "warn")
        if r.deleteAfter ?? p.deleteAfterImport, !saved.isEmpty {
            try await deleteVerified(saved)
        }
        lock.withLock { busy?.done = nil; busy?.total = nil; busy?.rate = nil }
        if !Task.isCancelled { try? await refresh(previews: false) }
    }

    /// Delete from the glasses only what arrived whole: checksum good (MediaImport keeps nothing else), and
    /// every saved file still on disk with the size the glasses announced.
    private func deleteVerified(_ saved: [MediaImport.Saved]) async throws {
        var safe: [Capture] = []
        for item in saved {
            guard let main = item.capture.main, let first = item.files.first,
                  let size = (try? FileManager.default.attributesOfItem(atPath: first.path)[.size] as? NSNumber)?.uint64Value,
                  size == main.size, item.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                log("Pas supprimé des lunettes (copie à vérifier) : \(item.capture.handle.prefix(8))", "warn")
                continue
            }
            safe.append(item.capture)
        }
        guard !safe.isEmpty else { return }
        setDetail("Reconnexion Bluetooth pour supprimer \(safe.count) éléments des lunettes…")
        try await deleteHandles(safe.map(\.handle))
    }

    private func phase(from line: String) {
        let map: [(String, String)] = [
            ("Asking the glasses for", "Les lunettes préparent les fichiers…"),
            ("Asking the glasses to host", "Les lunettes créent leur réseau Wi-Fi…"),
            ("The glasses host", "Le Mac rejoint le Wi-Fi des lunettes (pas d'internet pendant le transfert)…"),
            ("joined", "Connexion sécurisée en Wi-Fi…"),
            ("Connected over Wi-Fi", "Transfert en cours…"),
            ("Receiving", "Transfert en cours…"),
            ("The glasses went quiet", "Fin du transfert…"),
            ("back on", "Retour sur ton Wi-Fi…"),
        ]
        if let hit = map.first(where: { line.hasPrefix($0.0) }) { setDetail(hit.1) }
        if line.contains("damaged") || line.contains("giving up") || line.contains("dropped") || line.contains("could not") { log(line, "warn") }
    }

    // MARK: delete

    func deleteHandles(_ handles: [String]) async throws {
        let s = try await ensureSession()
        var ok = 0
        for (i, h) in handles.enumerated() {
            try Task.checkCancellation()
            setDetail("Suppression sur les lunettes : \(i + 1) / \(handles.count)")
            if try await s.deleteCapture(h) {
                ok += 1
                try? FileManager.default.removeItem(at: previewsDir.appendingPathComponent("\(h).jpg"))
                log("Supprimé des lunettes : \(h.prefix(8))", "ok")
            } else {
                log("Les lunettes ont refusé de supprimer \(h.prefix(8))", "warn")
            }
        }
        log("\(ok) sur \(handles.count) supprimés des lunettes", ok == handles.count ? "ok" : "warn")
        let list = try await s.listCaptures()
        lock.withLock { captures = list; capturesAt = Date() }
        pushState()
    }

    // MARK: Meta login and ownership

    func checkLogin() async throws {
        guard let tokens = store.tokens() else { throw UIError("les jetons de l'app Meta manquent (tokens.json)") }
        guard let frla = store.frla() else { throw UIError("pas de connexion Meta enregistrée") }
        setDetail("Vérification auprès de Meta…")
        do {
            _ = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
            lock.withLock { loginCheck = (true, Date(), "Meta accepte la connexion") }
        } catch {
            lock.withLock { loginCheck = (false, Date(), "\(error)") }
            pushState()
            throw error
        }
        pushState()
    }

    func pair() async throws {
        guard let tokens = store.tokens() else { throw UIError("les jetons de l'app Meta manquent (tokens.json)") }
        guard let frla = store.frla() else { throw UIError("pas de connexion Meta : voir la procédure dans l'onglet Compte") }
        // Informational only: LE finds the glasses by their identifier, classic pairing is not needed.
        let address = store.bundle()?.address ?? PairedGlasses.all().first?.address ?? ""
        disconnect()
        let key = try store.ownerKeyOrNew()
        setDetail("Connexion Meta…")
        let userToken = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
        let backend = PairingBackend(userToken: userToken, tokens: tokens)
        setDetail("Connexion Bluetooth (lunettes en mode appairage)…")
        let t = LeTransport(identifier: store.leIdentifier(), scanSeconds: 60)
        t.log = { [weak self] in self?.log($0, "debug") }
        let s = GlassesSession(transport: t, ownerKey: nil)
        s.log = { [weak self] in self?.log($0, "debug") }
        defer { s.close() }
        try await s.openBare()
        if let id = t.peripheralIdentifier { store.saveLeIdentifier(id) }
        let flow = IdentityFlow(connection: s.connection!)
        flow.log = { [weak self] in self?.log($0, "debug") }
        let final = try await flow.changeOwner(backend: backend, appPubkey: key.publicKey64) { [weak self] step in
            self?.setDetail("Appairage : \(step)")
            self?.log("Appairage : \(step)")
        }
        let info = final.info
        let serial = info["serial"] as? String ?? ""
        let userId = (info["user_id"] as? String) ?? (info["user_id"] as? NSNumber).map { "\($0)" } ?? ""
        try store.saveBundle(Store.Bundle(serial: serial, userId: userId, address: address, pairedAt: Date()))
        log("Ce Mac est propriétaire des lunettes : série \(serial)", "ok")
        pushState()
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
