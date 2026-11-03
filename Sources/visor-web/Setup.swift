import AppKit
import Foundation

/// The guided setup: runs setup.sh in machine mode (SETUP_MACHINE=1) and turns its "@@kind<TAB>field" lines
/// into a state the setup page draws. Answers to its questions go back on its stdin. The script stays the
/// one implementation of the setup; this is only another face for it.
final class SetupRunner {
    struct Line: Encodable {
        let kind: String  // ok, info, warn, skip, error, out
        let text: String
    }

    struct Step: Encodable {
        let key: String
        var title: String
        var status = "pending"  // pending, running, done, skipped, failed
        var lines: [Line] = []
        var worked = false
        var skipped = false
    }

    struct Activity: Encodable {
        var what: String
        var secs: Int
        var detail: String?
    }

    struct Prompt: Encodable {
        let kind: String  // ask: yes or no; pause: a go-ahead
        let key: String
        let text: String
    }

    struct Existing: Encodable {
        let tokens: Bool
        let login: Bool
        let paired: Bool
        let app: Bool
        let serial: String?
    }

    struct State: Encodable {
        let phase: String  // idle, running, done, failed, stopped
        let steps: [Step]
        let current: String?
        let activity: Activity?
        let action: String?
        let prompt: Prompt?
        let failure: String?
        let logPath: String?
        let exportDir: String?
        let existing: Existing
        let repo: String
        let startedAt: Date?
    }

    static let allSteps: [(String, String)] = [
        ("mac", "Checking this Mac"), ("build", "Building the Mac client"), ("tokens", "Meta app tokens"),
        ("login", "Meta login"), ("pair", "Pairing"), ("app", "Glasses.app"), ("cleanup", "Cleaning up"),
    ]

    let repo: URL
    private let lock = NSLock()
    private var phase = "idle"
    private var steps: [Step] = SetupRunner.allSteps.map { Step(key: $0.0, title: $0.1) }
    private var current: Int?
    private var activity: Activity?
    private var action: String?
    private var prompt: Prompt?
    private var failure: String?
    private var logPath: String?
    private var exportDir: String?
    private var startedAt: Date?
    private var process: Process?
    private var stdin: FileHandle?
    private var pending = Data()
    private var detail: [String] = []
    private var clients: [EventClient] = []
    private var statePending = false

    init(repo: URL) {
        self.repo = repo
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.broadcast("ping", Data("{}".utf8)) }
    }

    // MARK: state and events

    func existing() -> Existing {
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("visor-mac")
        func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: store.appendingPathComponent(name).path) }
        var serial: String?
        if let data = try? Data(contentsOf: store.appendingPathComponent("glasses.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { serial = json["serial"] as? String }
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Glasses.app")
        return Existing(tokens: has("tokens.json"), login: has("meta_login.txt"), paired: has("glasses.json") && has("owner_key.pem"),
                        app: FileManager.default.fileExists(atPath: app.path), serial: serial)
    }

    func state() -> State {
        let s = lock.withLock { (phase, steps, current.map { steps[$0].key }, activity, action, prompt, failure, logPath, exportDir, startedAt) }
        return State(phase: s.0, steps: s.1, current: s.2, activity: s.3, action: s.4, prompt: s.5, failure: s.6, logPath: s.7,
                     exportDir: s.8, existing: existing(), repo: repo.path, startedAt: s.9)
    }

    func details() -> [String] { lock.withLock { detail } }

    func addClient(_ c: EventClient) {
        lock.withLock { clients.removeAll { !$0.alive }; clients.append(c) }
        c.send("state", encode(state()))
    }

    private func broadcast(_ event: String, _ data: Data) {
        let all = lock.withLock { clients.removeAll { !$0.alive }; return clients }
        for c in all { c.send(event, data) }
    }

    /// At most four pushes a second: ticks come every two seconds per running command.
    private func pushState() {
        let go = lock.withLock { () -> Bool in if statePending { return false }; statePending = true; return true }
        guard go else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.statePending = false }
            self.broadcast("state", self.encode(self.state()))
        }
    }

    private func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(v)) ?? Data("null".utf8)
    }

    // MARK: running setup.sh

    struct StartOptions: Decodable {
        var relogin: Bool?
        var repair: Bool?
        var cleanup: Bool?
        var noApp: Bool?
    }

    func start(_ o: StartOptions) -> HTTPResponse {
        // VISOR_SETUP_SCRIPT: another script speaking the same protocol, to try the page without touching anything.
        let script = ProcessInfo.processInfo.environment["VISOR_SETUP_SCRIPT"].map { URL(fileURLWithPath: $0) } ?? repo.appendingPathComponent("setup.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .error(500, "setup.sh not found in \(repo.path)")
        }
        var args: [String] = []
        if o.relogin == true { args.append("--relogin") }
        if o.repair == true { args.append("--repair") }
        if o.cleanup == true { args.append("--cleanup") }
        if o.noApp == true { args.append("--no-app") }
        let refused: Bool = lock.withLock {
            if phase == "running" { return true }
            phase = "running"
            let keys = o.cleanup == true ? ["mac", "cleanup"] : SetupRunner.allSteps.map(\.0)
            steps = SetupRunner.allSteps.filter { keys.contains($0.0) }.map { Step(key: $0.0, title: $0.1) }
            current = nil; activity = nil; action = nil; prompt = nil; failure = nil; exportDir = nil
            startedAt = Date(); detail = []; pending = Data()
            return false
        }
        if refused { return .error(409, "The setup is already running") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["SETUP_MACHINE"] = "1"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.feed(data)
        }
        p.terminationHandler = { [weak self] proc in self?.finished(proc.terminationStatus) }
        do {
            try p.run()
        } catch {
            lock.withLock { phase = "failed"; failure = "Could not start setup.sh: \(error)" }
            pushState()
            return .error(500, "could not start setup.sh")
        }
        lock.withLock { process = p; stdin = input.fileHandleForWriting }
        note("$ setup.sh \(args.joined(separator: " "))")
        pushState()
        return .ok()
    }

    /// Answer the question on screen: "yes" or "no" for an ask, anything for a pause.
    func answer(key: String, value: String) -> HTTPResponse {
        let handle: FileHandle? = lock.withLock {
            guard let p = prompt, p.key == key else { return nil }
            prompt = nil
            return stdin
        }
        guard let handle else { return .error(409, "No such question on screen") }
        let line = value == "yes" ? "yes\n" : value == "no" ? "no\n" : "\n"
        try? handle.write(contentsOf: Data(line.utf8))
        note("> \(key): \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        pushState()
        return .ok()
    }

    /// Stop the setup the way Ctrl-C does: its own trap reports it and exits. The script's direct children
    /// (a download, a build, the pairing) get the signal too, so it does not wait for them.
    func stop() -> HTTPResponse {
        guard let p = lock.withLock({ process }), p.isRunning else { return .error(409, "The setup is not running") }
        let pid = p.processIdentifier
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-INT", "-P", "\(pid)"]
        try? kill.run()
        p.interrupt()
        note("Stop requested")
        return .ok()
    }

    var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    private func finished(_ status: Int32) {
        lock.withLock {
            if !pending.isEmpty { let rest = pending; pending = Data(); lines(from: rest + Data("\n".utf8)) }
            if phase == "running" || phase == "stopped" {
                if phase == "stopped" || status == 130 || failure == "Stopped." {
                    phase = "stopped"
                } else if status == 0 {
                    phase = "done"
                } else {
                    phase = "failed"
                    failure = failure ?? "The setup stopped unexpectedly (exit code \(status))."
                }
            }
            if phase == "stopped" || phase == "failed", let i = current, steps[i].status == "running" {
                steps[i].status = phase == "stopped" ? "pending" : "failed"
            }
            activity = nil
            prompt = nil
            process = nil
            stdin = nil
            detail.append("setup.sh ended with code \(status)")
        }
        pushState()
    }

    private func note(_ text: String) {
        lock.withLock { detail.append(text); if detail.count > 3000 { detail.removeFirst(detail.count - 3000) } }
    }

    private func feed(_ data: Data) {
        lock.withLock {
            pending.append(data)
            guard let last = pending.lastIndex(of: 0x0A) else { return }
            let complete = pending[...last]
            pending = Data(pending[pending.index(after: last)...])
            lines(from: Data(complete))
        }
        pushState()
    }

    /// Under the lock.
    private func lines(from data: Data) {
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            handle(String(raw))
        }
    }

    /// One line from setup.sh, under the lock.
    private func handle(_ line: String) {
        detail.append(line.hasPrefix("@@") ? String(line.dropFirst(2)).replacingOccurrences(of: "\t", with: "  ") : line)
        if detail.count > 3000 { detail.removeFirst(detail.count - 3000) }
        guard line.hasPrefix("@@") else { append("out", line); return }
        let parts = line.dropFirst(2).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let kind = parts[0]
        let f = Array(parts.dropFirst())
        func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
        switch kind {
        case "step":
            closeStep()
            let key = field(2)
            if let i = steps.firstIndex(where: { $0.key == key }) {
                steps[i].status = "running"
                if !field(3).isEmpty { steps[i].title = field(3) }
                current = i
            }
        case "ok":
            append("ok", field(0)); activity = nil
            if let i = current { steps[i].worked = true }
        case "skip":
            append("skip", field(0))
            if let i = current { steps[i].skipped = true }
        case "info": append("info", field(0))
        case "warn": append("warn", field(0))
        case "run":
            activity = Activity(what: field(0), secs: 0, detail: nil)
            if let i = current { steps[i].worked = true }
        case "tick":
            activity = Activity(what: field(1), secs: Int(field(0)) ?? 0, detail: field(2).isEmpty ? nil : field(2))
        case "runfail":
            append("error", "\(field(0)) (exit \(field(1)))"); activity = nil
        case "out": append("out", field(0))
        case "ask", "pause": prompt = Prompt(kind: kind, key: field(0), text: field(1))
        case "action": action = field(0) == "none" ? nil : field(0)
        case "log": logPath = field(0)
        case "fail":
            failure = field(0)
            if let i = current { steps[i].status = field(0) == "Stopped." ? "pending" : "failed" }
            phase = field(0) == "Stopped." ? "stopped" : "failed"
            activity = nil; prompt = nil; action = nil
        case "stopped":
            failure = field(0)
            if let i = current { steps[i].status = "pending" }
            phase = "stopped"
            activity = nil; prompt = nil; action = nil
        case "done":
            closeStep()
            exportDir = field(0).isEmpty ? nil : field(0)
            phase = "done"
            activity = nil; prompt = nil; action = nil
        default:
            append("out", line)
        }
    }

    private func closeStep() {
        guard let i = current, steps[i].status == "running" else { return }
        steps[i].status = steps[i].skipped && !steps[i].worked ? "skipped" : "done"
    }

    private func append(_ kind: String, _ text: String) {
        guard let i = current else { return }
        steps[i].lines.append(Line(kind: kind, text: text))
        if steps[i].lines.count > 200 { steps[i].lines.removeFirst(steps[i].lines.count - 200) }
    }
}

/// The setup page's HTTP API, on its own port so that it can run beside Glasses.app.
final class SetupRoutes {
    let runner: SetupRunner
    let port: UInt16
    let webDir: URL
    static let appPort: UInt16 = 47392

    init(runner: SetupRunner, port: UInt16, webDir: URL) {
        self.runner = runner
        self.port = port
        self.webDir = webDir
    }

    func handle(_ r: HTTPRequest) async -> HTTPResponse {
        guard Routes.allowed(r, port: port) else { return .text(403, "forbidden") }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/setup.html"):
            var resp = file("setup.html")
            // The page checks that Glasses answers on its own port before sending the person there.
            resp.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self' http://127.0.0.1:\(SetupRoutes.appPort); frame-ancestors 'none'"
            return resp
        case ("GET", "/setup.js"), ("GET", "/app.css"), ("GET", "/setup.css"), ("GET", "/icon.svg"):
            return file(String(r.path.dropFirst()))
        case ("GET", "/api/setup/state"): return .json(runner.state())
        case ("GET", "/api/setup/events"): return HTTPResponse(status: 200, headers: [:], body: .events)
        case ("GET", "/api/setup/details"): return .json(runner.details())
        case ("POST", "/api/setup/start"):
            return runner.start(r.json(SetupRunner.StartOptions.self) ?? SetupRunner.StartOptions())
        case ("POST", "/api/setup/answer"):
            struct A: Decodable { let key: String; let value: String }
            guard let a = r.json(A.self) else { return .error(400, "bad answer") }
            return runner.answer(key: a.key, value: a.value)
        case ("POST", "/api/setup/stop"): return runner.stop()
        case ("POST", "/api/setup/log"):
            if let path = runner.state().logPath { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            return .ok()
        case ("POST", "/api/setup/open-app"):
            let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Glasses.app")
            guard FileManager.default.fileExists(atPath: app.path) else { return .error(404, "Glasses.app is not installed") }
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--no-open"]
            DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: app, configuration: config) }
            return .ok()
        case ("POST", "/api/setup/quit"):
            if runner.isRunning { return .error(409, "The setup is still running") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return .ok()
        default:
            return .text(404, "not found")
        }
    }

    private func file(_ name: String) -> HTTPResponse {
        let url = webDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .text(404, "missing \(name) in \(webDir.path)") }
        return .file(url)
    }
}
