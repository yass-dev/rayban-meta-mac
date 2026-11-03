import Foundation
import VisorKit

// visor-mac: a macOS client for Meta's glasses, built on the protocol Visor documented.
// The main thread runs the run loop for IOBluetooth; the work runs in one Task.

struct Args {
    var command = "help"
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") { command = first; rest.removeFirst() }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") { flags[name] = rest[i + 1]; i += 2 } else { switches.insert(name); i += 1 }
            } else { i += 1 }
        }
    }

    func has(_ name: String) -> Bool { switches.contains(name) || flags[name] != nil }
}

let args = Args(CommandLine.arguments)
/// Bluetooth LE is the path that works from a Mac; RFCOMM channel 7 is refused by the glasses.
let useLe = !args.has("rfcomm")
var leTransport: LeTransport?

/// Remember the glasses' LE identifier once a connection has seen them.
func rememberLe() {
    if let id = leTransport?.peripheralIdentifier, id != store.leIdentifier() {
        store.saveLeIdentifier(id)
        say("Remembered the glasses' LE identifier \(id)")
    }
}
let verbose = args.has("verbose")
let store = Store()

func say(_ text: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss.SSS"
    print("[\(stamp.string(from: Date()))] \(text)")
    fflush(stdout)
}

func debug(_ text: String) { if verbose { say("  " + text) } }

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("error: \(text)\n".utf8))
    exit(1)
}

func usage() {
    print("""
    visor-mac: Meta glasses from a Mac, over Bluetooth LE and the glasses' own Wi-Fi.
    First time: run ./setup.sh from the repository, it does the Meta login and the pairing.

      status                       connect as owner: build, serial, model
      list                         the captures on the glasses
      import [--all | --handle H] [--out DIR] [--keep-logs] [--country CC]
                                   fetch new captures (or all) over the glasses' Wi-Fi into DIR
                                   (default: the app's export folder, else ~/Pictures/Ray-Ban Meta)
      delete --handle H            delete one capture from the glasses
      check-login                  check the stored Meta login with Meta
      export-dir                   print the folder imports go to
      pair --yes                   make this Mac the owner of the glasses (the Meta AI app loses them)
      probe                        handshake only, then read the glasses' identity (no ownership needed)
      devices                      the glasses paired in System Settings > Bluetooth
      le-scan [--seconds N]        what advertises over Bluetooth LE
      login --window | --start | --redirect U
                                   Meta's web login; Meta currently refuses its code (HTTP 500)

    Options: --rfcomm (Bluetooth Classic channel 7 instead of LE; the glasses refuse it from a Mac),
             --address AA:BB:CC:DD:EE:FF, --le-id UUID, --verbose, --trace
    State:   ~/Library/Application Support/visor-mac/ (owner key, Meta login, app tokens), files chmod 600
    """)
}

func glassesAddress() -> String {
    if let a = args.flags["address"] { return a }
    if let b = store.bundle() { return b.address }
    let paired = PairedGlasses.all()
    if let first = paired.first { return first.address }
    // LE finds the glasses by their identifier: the classic address is only a label then.
    guard useLe else { fail("no paired Meta glasses. Pair them in System Settings > Bluetooth first, or pass --address") }
    return ""
}

func rfcomm(_ address: String) -> RfcommTransport {
    let t = RfcommTransport(address: address)
    t.log = debug
    return t
}

/// LE when asked for, else RFCOMM. The glasses keep the LE link up while asleep in the case; RFCOMM needs them awake.
func transport(_ address: String) -> Transport {
    if useLe {
        let id = args.flags["le-id"].flatMap(UUID.init(uuidString:)) ?? store.leIdentifier()
        let t = LeTransport(identifier: id, scanSeconds: 30)
        t.log = debug
        leTransport = t
        return t
    }
    return rfcomm(address)
}

func cmdLeScan() async throws {
    let t = LeTransport(scanSeconds: Double(args.flags["seconds"] ?? "") ?? 12)
    t.log = debug
    say("Scanning Bluetooth LE for \(Int(12)) s (bonded glasses may not advertise to a stranger)")
    let seen = try await t.scan()
    say("\(seen.count) peripherals seen, \(seen.filter(\.looksLikeMeta).count) that look like Meta")
    for p in seen where p.looksLikeMeta || verbose {
        say("\(p.looksLikeMeta ? "META " : "     ")\(p.name.isEmpty ? "(no name)" : p.name)  rssi \(p.rssi)  id \(p.identifier)  services \(p.services)  manufacturer \(p.manufacturerId.map { String(format: "0x%04x", $0) } ?? "-") \(p.manufacturerData.hex)")
    }
}

func session(_ transport: Transport, key: OwnerKey?) -> GlassesSession {
    let tapped: Transport = args.has("trace") ? WireTap(transport) { out, sdu in say("  \(out ? "tx" : "rx") \(sdu.count)B \(sdu.prefix(24).hex)") } : transport
    let s = GlassesSession(transport: tapped, ownerKey: key)
    s.log = debug
    if args.has("trace") { s.trace = { say("  " + $0) } }
    s.onUnhandled = { m, svc in debug(String(format: "svc %d type 0x%04x, %d bytes", svc, m.info.messageType, m.payload.count)) }
    return s
}

func ownerKeyOrFail() -> OwnerKey {
    guard let key = try? store.ownerKey() else { fail("no owner key yet: run `visor-mac pair` first") }
    return key
}

func cmdDevices() {
    let paired = PairedGlasses.all()
    if paired.isEmpty { say("No paired Meta glasses. Put them in pairing mode and pair in System Settings > Bluetooth.") }
    for d in paired {
        say("\(d.name)  \(d.address)  product \(d.productId)\(d.productId == 266 ? " (Ray-Ban Meta Gen 2)" : "")  \(d.connected ? "connected" : "not connected")  Meta RFCOMM channel \(d.rfcommChannel.map(String.init) ?? "?")")
    }
    if let b = store.bundle() { say("Owned by this Mac: serial \(b.serial) at \(b.address), paired \(b.pairedAt)") }
}

func cmdProbe() async throws {
    let address = glassesAddress()
    say("Opening \(useLe ? "LE L2CAP" : "RFCOMM") to \(address)")
    let s = session(transport(address), key: nil)
    try await s.openBare()
    rememberLe()
    say("AirShield handshake done: ECDH, keys derived")
    let flow = IdentityFlow(connection: s.connection!, timeout: 10)
    flow.log = debug
    let identity = try await flow.identity()
    say("Serial: \(identity.serial)")
    say("Device certificate: \(identity.certDer.count) bytes DER, sha256 \(Hash.sha256(identity.certDer).hex.prefix(16))")
    if let subject = certificateSubject(identity.certDer) { say("Certificate subject: \(subject)") }
    s.close()
}

func certificateSubject(_ der: [UInt8]) -> String? {
    guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return nil }
    return SecCertificateCopySubjectSummary(cert) as String?
}

func readLine(prompt: String) -> String {
    print(prompt, terminator: "")
    fflush(stdout)
    return Swift.readLine() ?? ""
}

func cmdLogin() async throws {
    guard let tokens = store.tokens() else {
        fail("the Meta app tokens are missing. Set VISOR_META_HW_TOKEN and VISOR_META_AR_TOKEN, or write tokens.json in \(store.directory.path)")
    }
    let stateFile = store.directory.appendingPathComponent("login_state.txt")
    if let redirect = args.flags["redirect"] {
        guard let state = try? String(contentsOf: stateFile, encoding: .utf8) else { fail("no login in progress: run `visor-mac login --start` first") }
        let code = try MetaLogin.codeFromRedirect(redirect, expectedState: state.trimmingCharacters(in: .whitespacesAndNewlines))
        say("Exchanging the code for a login token")
        let frla = try await MetaLogin.exchangeCode(code)
        try store.saveFrla(frla)
        try? FileManager.default.removeItem(at: stateFile)
        say("Checking it with Meta's AR login")
        _ = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
        say("Logged in. The token is kept in \(store.directory.path)")
        return
    }
    let request = MetaLogin.authorizeRequest()
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data(request.state.utf8).write(to: stateFile, options: .atomic)
    print(request.url)
    if !args.has("start") {
        say("Open that URL, log in, then run: visor-mac login --redirect '<the URL the browser lands on>'")
    }
}

func cmdCheckLogin() async throws {
    guard let tokens = store.tokens() else { fail("the Meta app tokens are missing") }
    guard let frla = store.frla() else { fail("not logged in to Meta") }
    _ = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
    say("The Meta login works: the AR login accepted it")
}

func cmdPair() async throws {
    guard args.has("yes") else {
        fail("""
        pair makes this Mac the owner of the glasses: the Meta AI app on your phone loses them until you
        set them up again there. Run `visor-mac pair --yes` to go ahead.
        """)
    }
    guard let tokens = store.tokens() else { fail("the Meta app tokens are missing (see `visor-mac help`)") }
    guard let frla = store.frla() else { fail("not logged in to Meta: run `visor-mac login` first") }
    let address = glassesAddress()
    let key = try store.ownerKeyOrNew()
    say("Owner key ready (sha256 \(key.keyHash.hex.prefix(16)))")
    say("AR login")
    let userToken = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
    let backend = PairingBackend(userToken: userToken, tokens: tokens)
    say("Opening \(useLe ? "LE L2CAP" : "RFCOMM") to \(address)")
    let s = session(transport(address), key: nil)
    try await s.openBare()
    rememberLe()
    let flow = IdentityFlow(connection: s.connection!)
    flow.log = debug
    let final = try await flow.changeOwner(backend: backend, appPubkey: key.publicKey64) { say("  step: \($0)") }
    s.close()
    let info = final.info
    let serial = info["serial"] as? String ?? ""
    let userId = (info["user_id"] as? String) ?? (info["user_id"] as? NSNumber).map { "\($0)" } ?? ""
    try store.saveBundle(Store.Bundle(serial: serial, userId: userId, address: address, pairedAt: Date()))
    say("This Mac now owns the glasses: serial \(serial), user \(userId)")
}

func openAsOwner() async throws -> GlassesSession {
    let key = ownerKeyOrFail()
    let address = glassesAddress()
    say("Opening \(useLe ? "LE L2CAP" : "RFCOMM") to \(address)")
    let s = session(transport(address), key: key)
    try await s.open()
    rememberLe()
    if let t = s.trustResult, !t.complete {
        say("Trust incomplete (tx \(t.txOk), rx \(t.rxOk)\(t.refusal.map { ", " + IdentityStatus.name($0) } ?? "")): the glasses may refuse every service")
    } else {
        say("Session ready, trust ok")
    }
    return s
}

func cmdStatus() async throws {
    let s = try await openAsOwner()
    let info = try await s.peerDeviceInfo()
    say("Glasses: \(info)")
    s.close()
}

func describe(_ c: Capture) -> String {
    let when = c.takenAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "no date"
    let size = c.main.map { sizeWords($0.size) } ?? "-"
    return "\(c.handle.prefix(8))  \(c.type.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  \(when)  \(size)\(c.isNew ? "  new" : "")\(c.landscape ? "  landscape" : "")"
}

func cmdList() async throws {
    let s = try await openAsOwner()
    let captures = try await s.listCaptures()
    say("\(captures.count) captures on the glasses, \(captures.filter(\.isNew).count) new")
    for c in captures { print("  " + describe(c)) }
    s.close()
}

func cmdImport() async throws {
    let out = args.flags["out"].map { URL(fileURLWithPath: $0) } ?? store.exportDirectory()
    let key = ownerKeyOrFail()
    let s = try await openAsOwner()
    let captures = try await s.listCaptures()
    var chosen = args.has("all") ? captures.filter(\.isMedia) : captures.filter { $0.isMedia && $0.isNew }
    if let handle = args.flags["handle"] { chosen = captures.filter { $0.isMedia && $0.handle.hasPrefix(handle) } }
    say("\(captures.count) captures on the glasses, importing \(chosen.count)\(args.has("all") ? "" : " new (use --all for everything)")")
    guard !chosen.isEmpty else { s.close(); return }
    for c in chosen { print("  " + describe(c)) }
    var options = MediaImport.Options(output: out)
    options.country = args.flags["country"] ?? "FR"
    options.keepLogs = args.has("keep-logs")
    let job = MediaImport(bluetooth: s, ownerKey: key, captures: chosen, options: options, log: say)
    try await job.run()
    say("Done: \(job.saved.count) of \(chosen.count) captures saved in \(out.path)")
}

func cmdDelete() async throws {
    guard let handle = args.flags["handle"] else { fail("--handle is required") }
    let s = try await openAsOwner()
    let captures = try await s.listCaptures()
    guard let c = captures.first(where: { $0.handle.hasPrefix(handle) }) else { fail("no capture starts with \(handle)") }
    let ok = try await s.deleteCapture(c.handle)
    say(ok ? "Deleted \(c.handle)" : "The glasses kept \(c.handle)")
    s.close()
}

if args.command == "login", args.has("window") { runLoginWindow() }

Task {
    do {
        switch args.command {
        case "devices": cmdDevices()
        case "le-scan": try await cmdLeScan()
        case "probe": try await cmdProbe()
        case "login": try await cmdLogin()
        case "pair": try await cmdPair()
        case "check-login": try await cmdCheckLogin()
        case "export-dir": print(store.exportDirectory().path)
        case "status": try await cmdStatus()
        case "list": try await cmdList()
        case "import": try await cmdImport()
        case "delete": try await cmdDelete()
        default: usage()
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}
RunLoop.main.run()
