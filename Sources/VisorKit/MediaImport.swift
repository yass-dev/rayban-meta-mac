import Foundation

/// Lists the captures on the glasses, fetches them over the glasses' own Wi-Fi network, and files them
/// under a folder by date. A simplified port of Visor's `MediaImport.kt` for one session at a time.
public final class MediaImport {
    public struct Options {
        public var output: URL
        public var country = "FR"
        public var deleteAfter = false
        public var keepLogs = false
        public var idleSeconds: TimeInterval = 15
        public var maxSeconds: TimeInterval = 30 * 60
        public init(output: URL) { self.output = output }
    }

    public struct Saved {
        public let capture: Capture
        public let files: [URL]
    }

    private let bluetooth: GlassesSession
    private let ownerKey: OwnerKey
    private let options: Options
    private let log: (String) -> Void
    private let spool: URL
    private var captures: [Capture]
    private var awaited: Set<String> = []
    private var pieces: [String: [String: Received]] = [:]
    public private(set) var saved: [Saved] = []
    /// A file in flight: the capture's handle, the asset id, bytes so far, the asset's size.
    public var onProgress: (String, String, UInt64, UInt64) -> Void = { _, _, _, _ in }
    /// A capture whose files all arrived with a good checksum and were moved into the output folder.
    public var onSaved: (Saved) -> Void = { _ in }
    /// The Mac left its own network for the glasses' (true), or came back (false).
    public var onOffline: (Bool) -> Void = { _ in }
    private var tcpAddress: String?

    public init(bluetooth: GlassesSession, ownerKey: OwnerKey, captures: [Capture], options: Options, log: @escaping (String) -> Void) {
        self.bluetooth = bluetooth
        self.ownerKey = ownerKey
        self.captures = captures
        self.options = options
        self.log = log
        spool = options.output.appendingPathComponent(".spool", isDirectory: true)
    }

    /// Ask for the captures over Bluetooth, move the glasses onto their own Wi-Fi, take the files over TCP.
    public func run() async throws {
        let wanted = captures.filter { !$0.wanted.isEmpty }
        guard !wanted.isEmpty else { log("Nothing to import"); return }
        awaited = Set(wanted.flatMap { $0.wanted.map(\.id) })
        log("Asking the glasses for \(wanted.count) captures (\(awaited.count) files)")
        for capture in wanted {
            // An asset already delivered is skipped by the capture request; asked for on its own, it comes too.
            for asset in capture.wanted where asset.delivered {
                try await bluetooth.requestAsset(capture.handle, assetId: asset.id)
            }
            try await bluetooth.requestCapture(capture.handle, linkType: MediaService.linkWifi)
        }

        let ssid = "Visor-Mac-" + Random.bytes(2).hex
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let password = String(Random.bytes(16).map { alphabet[Int($0) % alphabet.count] })
        log("Asking the glasses to host Wi-Fi network \(ssid)")
        let info = try await bluetooth.createSoftAp(ssid: ssid, password: password, country: options.country)
        guard info.ok, let address = info.address else {
            throw WifiError("the glasses did not bring their network up: \(info)")
        }
        log("The glasses host \(info.ssid) at \(address):\(info.port)")
        tcpAddress = address

        let iface = MacWifi.interface()
        let home = MacWifi.currentSsid(iface)
        onOffline(true)
        defer {
            if let home, home != info.ssid { MacWifi.rejoin(iface, ssid: home, log: log) }
            onOffline(false)
        }
        try MacWifi.join(iface, ssid: info.ssid, password: info.password, peer: address, log: log)

        let transport = TcpTransport(host: address, port: info.port)
        let wifi = GlassesSession(transport: transport, ownerKey: ownerKey)
        wifi.log = log
        let receiver = AirshipReceiver(spool: spool)
        receiver.note = log
        receiver.describe = { [weak self] id in self?.describe(id) ?? "" }
        receiver.onReceived = { [weak self] received in self?.keep(received) }
        receiver.onProgress = { [weak self] id, got, size in
            guard let self, let c = self.captures.first(where: { c in c.assets.contains { $0.id == id } }) else { return }
            self.onProgress(c.handle, id, got, size)
        }
        wifi.addResponder(ServiceIds.airship, receiver.respond)
        var lost = false
        wifi.onLost = { _ in lost = true }

        log("Opening a session over Wi-Fi")
        guard try await withDeadline(45, { try await wifi.open() }) != nil else {
            throw WifiError("the glasses did not open a session over Wi-Fi")
        }
        log("Connected over Wi-Fi, trust \(wifi.trustResult?.complete == true ? "ok" : "incomplete")")
        // The glasses drop the Bluetooth session once Wi-Fi is up. Let ours go too.
        bluetooth.close()

        let readyAt = Date()
        while !lost {
            // Cancelled: stop asking, but still close the glasses' network and keep what arrived whole.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { log("Import cancelled"); break }
            if receiver.inFlight == 0, awaited.isEmpty { break }
            let quiet = Date().timeIntervalSince(max(receiver.lastActivity, readyAt))
            if receiver.inFlight == 0, quiet > options.idleSeconds {
                log("The glasses went quiet for \(Int(quiet)) s with \(awaited.count) files still missing")
                break
            }
            // A file stuck halfway: the Mac left the glasses' network, or they went to sleep.
            if receiver.inFlight > 0, quiet > 30 {
                log("No data for \(Int(quiet)) s in the middle of a file: giving up on this session")
                break
            }
            if Date().timeIntervalSince(readyAt) > options.maxSeconds { break }
        }
        if lost { log("The Wi-Fi link dropped") }
        if !lost { try? await wifi.destroySoftAp() }
        wifi.close()
        receiver.abandon()
        finishAll()
        try? FileManager.default.removeItem(at: spool)

        if options.deleteAfter, !saved.isEmpty {
            log("Deleting \(saved.count) captures from the glasses needs a Bluetooth session: run `visor-mac delete` after this")
        }
    }

    private func describe(_ assetId: String) -> String {
        guard let capture = captures.first(where: { c in c.assets.contains { $0.id == assetId } }) else { return " (\(assetId.prefix(8)), not in the list)" }
        let what: String
        switch assetId {
        case capture.main?.id: what = capture.type == .video ? "video" : "photo"
        case capture.motion?.id: what = "live clip"
        case capture.preview?.id: what = "preview"
        case capture.imu?.id: what = "motion log"
        case capture.frames?.id: what = "frame log"
        default: what = "asset"
        }
        return " (\(what) of \(capture.handle.prefix(8)))"
    }

    private func keep(_ received: Received) {
        awaited.remove(received.offer.uuid)
        guard let index = captures.firstIndex(where: { c in c.assets.contains { $0.id == received.offer.uuid } }) else {
            log("A file nothing asked for arrived (\(received.offer.uuid.prefix(8))), kept as is")
            _ = try? move(received.file, to: options.output.appendingPathComponent("unknown_\(received.offer.uuid.prefix(8)).\(extensionOf(received.file) ?? "bin")"))
            return
        }
        let capture = captures[index]
        guard received.verified else {
            log("A file arrived damaged and was not kept\(describe(received.offer.uuid))")
            try? FileManager.default.removeItem(at: received.file)
            return
        }
        pieces[capture.handle, default: [:]][received.offer.uuid] = received
        captures[index].markDelivered(received.offer.uuid)
        let have = Set(pieces[capture.handle]!.keys)
        if capture.wanted.allSatisfy({ have.contains($0.id) }) { finish(capture) }
    }

    private func finishAll() {
        for capture in captures where pieces[capture.handle] != nil { finish(capture) }
    }

    private func finish(_ capture: Capture) {
        guard let got = pieces.removeValue(forKey: capture.handle), let main = capture.main, let mainFile = got[main.id] else { return }
        let stamp = MediaImport.name.string(from: capture.takenAt ?? Date())
        let base = "Visor_\(stamp)_\(capture.handle.prefix(6))"
        var files: [URL] = []
        do {
            let ext = extensionOf(mainFile.file) ?? (capture.type == .video ? "mp4" : "heic")
            files.append(try move(mainFile.file, to: options.output.appendingPathComponent("\(base).\(ext)")))
            if let motion = capture.motion, let clip = got[motion.id] {
                files.append(try move(clip.file, to: options.output.appendingPathComponent("\(base)_live.\(extensionOf(clip.file) ?? "mp4")")))
            }
            if options.keepLogs {
                if let imu = capture.imu, let f = got[imu.id] { files.append(try move(f.file, to: options.output.appendingPathComponent("\(base).imu"))) }
                if let fr = capture.frames, let f = got[fr.id] { files.append(try move(f.file, to: options.output.appendingPathComponent("\(base).frames"))) }
            }
            for (id, r) in got where !files.contains(r.file) && (capture.main?.id != id) {
                try? FileManager.default.removeItem(at: r.file)
            }
            if let taken = capture.takenAt {
                for f in files { try? FileManager.default.setAttributes([.creationDate: taken, .modificationDate: taken], ofItemAtPath: f.path) }
            }
            let done = Saved(capture: capture, files: files)
            saved.append(done)
            onSaved(done)
            log("Saved \(capture.type.rawValue) \(files.first!.lastPathComponent)")
        } catch {
            log("Could not save \(capture.handle.prefix(8)): \(error)")
        }
    }

    private func move(_ from: URL, to: URL) throws -> URL {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target = to
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = to.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension(to.pathExtension)
            n += 1
        }
        try FileManager.default.moveItem(at: from, to: target)
        return target
    }

    /// jpg, heic or mp4 from the first bytes, or nil for anything else (the sensor logs).
    private func extensionOf(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 12) else { return nil }
        try? handle.close()
        let b = head.bytes
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 12, String(bytes: b[4 ..< 8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: b[8 ..< 12], encoding: .ascii) ?? ""
            return ["heic", "heix", "hevc", "mif1", "msf1", "heim", "heis"].contains(brand) ? "heic" : "mp4"
        }
        return nil
    }

    static let name: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
