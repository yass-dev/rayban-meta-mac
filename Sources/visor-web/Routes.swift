import AppKit
import Foundation
import VisorKit

/// The HTTP API. Every route checks it is called from this Mac's own page: the Host must be the loopback
/// address (no DNS rebinding), and every change needs the X-Visor header, which a foreign page cannot
/// send without a CORS preflight this server never grants.
final class Routes {
    let c: Controller
    let port: UInt16
    let webDir: URL
    /// Add-ons register more routes here: method + path -> handler.
    var extra: [String: (HTTPRequest) async -> HTTPResponse] = [:]

    init(controller: Controller, port: UInt16, webDir: URL) {
        c = controller
        self.port = port
        self.webDir = webDir
    }

    /// The loopback Host only (no DNS rebinding), the page's own Origin, and the X-Visor header on any change.
    static func allowed(_ r: HTTPRequest, port: UInt16) -> Bool {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = r.header("host"), hosts.contains(host.lowercased()) else { return false }
        if let origin = r.header("origin"), !hosts.map({ "http://" + $0 }).contains(origin.lowercased()) { return false }
        if r.method != "GET" && r.method != "HEAD" { return r.header("x-visor") == "1" }
        return true
    }

    func handle(_ r: HTTPRequest) async -> HTTPResponse {
        guard Routes.allowed(r, port: port) else { return .text(403, "forbidden") }
        if let h = extra["\(r.method) \(r.path)"] { return await h(r) }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"): return staticFile("index.html")
        case ("GET", "/app.js"), ("GET", "/app.css"), ("GET", "/icon.svg"): return staticFile(String(r.path.dropFirst()))

        case ("GET", "/api/state"): return .json(c.state())
        case ("GET", "/api/events"): return HTTPResponse(status: 200, headers: [:], body: .events)
        case ("GET", "/api/logs"): return .json(c.logsSnapshot())

        case ("POST", "/api/connect"):
            return c.start("connect", "Connecting to the glasses") { [c] in try await c.refresh(previews: c.prefs.autoPreviews) }
        case ("POST", "/api/disconnect"):
            if c.isBusy { return .error(409, "Something is running: cancel it first") }
            c.disconnect(); return .ok()
        case ("POST", "/api/refresh"):
            return c.start("refresh", "Refreshing the gallery") { [c] in try await c.refresh(previews: c.prefs.autoPreviews) }
        case ("POST", "/api/previews"):
            return c.start("previews", "Loading the previews") { [c] in try await c.refresh(previews: true) }
        case ("POST", "/api/cancel"): return c.cancel()

        case ("POST", "/api/import"):
            guard let body = r.json(Controller.ImportRequest.self) else { return .error(400, "invalid request") }
            let label = ["new": "Importing what is new", "all": "Importing everything", "selected": "Importing the selection"][body.mode] ?? "Importing what is missing on the Mac"
            return c.start("import", label) { [c] in try await c.importMedia(body) }

        case ("POST", "/api/delete"):
            struct D: Decodable { let handles: [String]; let confirm: Bool }
            guard let body = r.json(D.self), body.confirm, !body.handles.isEmpty else { return .error(400, "missing confirmation") }
            return c.start("delete", "Deleting from the glasses") { [c] in try await c.deleteHandles(body.handles) }

        case ("POST", "/api/check-login"):
            return c.start("login", "Checking the Meta login") { [c] in try await c.checkLogin() }
        case ("POST", "/api/pair"):
            struct P: Decodable { let confirm: String }
            guard r.json(P.self)?.confirm == "PAIR" else { return .error(400, "type PAIR to confirm") }
            return c.start("pair", "Pairing (taking ownership)", cancellable: false) { [c] in try await c.pair() }

        case ("POST", "/api/prefs"):
            guard let p = r.json(WebPrefs.self) else { return .error(400, "invalid preferences") }
            c.setPrefs(p); return .ok()

        case ("GET", _) where r.path.hasPrefix("/api/preview/"):
            let handle = String(r.path.dropFirst("/api/preview/".count))
            guard Routes.safeName(handle) else { return .text(400, "bad handle") }
            let url = c.previewsDir.appendingPathComponent("\(handle).jpg")
            return FileManager.default.fileExists(atPath: url.path) ? .file(url, type: "image/jpeg", cache: true) : .text(404, "no preview")

        case ("GET", "/api/library"):
            let items = c.library.items(in: c.exportDir, findDuplicates: r.query["dupes"] != "0")
            return .json(["dir": AnyEncodable(c.exportDir.path), "items": AnyEncodable(items)])
        case ("GET", "/api/thumb"):
            guard let url = libraryFile(r.query["name"]) else { return .text(404, "not found") }
            guard let t = c.library.thumbnail(of: url) else { return .text(415, "no thumbnail") }
            return .file(t, type: "image/jpeg", cache: true)
        case ("GET", "/api/view"):
            guard let url = libraryFile(r.query["name"]), let v = c.library.viewable(url) else { return .text(404, "not found") }
            return .file(v, cache: true)
        case ("GET", "/media"), ("HEAD", "/media"):
            guard let url = libraryFile(r.query["name"]) else { return .text(404, "not found") }
            var resp = HTTPResponse.file(url)
            if r.query["dl"] == "1" { resp.headers["Content-Disposition"] = "attachment; filename=\"\(url.lastPathComponent)\"" }
            return resp
        case ("POST", "/api/library/trash"):
            struct T: Decodable { let names: [String] }
            guard let body = r.json(T.self) else { return .error(400, "invalid request") }
            var moved = 0
            for n in body.names { if let url = libraryFile(n), (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { moved += 1 } }
            c.log("\(moved) file(s) moved to the Mac's Trash", "ok")
            c.pushState()
            return .ok("\(moved)")
        case ("POST", "/api/library/reveal"):
            struct N: Decodable { let name: String? }
            let body = r.json(N.self)
            if let n = body?.name, let url = libraryFile(n) {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                try? FileManager.default.createDirectory(at: c.exportDir, withIntermediateDirectories: true)
                let dir = c.exportDir
                DispatchQueue.main.async { NSWorkspace.shared.open(dir) }
            }
            return .ok()
        case ("POST", "/api/quit"):
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return .ok()
        default:
            return .text(404, "not found")
        }
    }

    static func safeName(_ s: String) -> Bool {
        !s.isEmpty && s.count < 200 && !s.contains("/") && !s.contains("\\") && !s.hasPrefix(".") && !s.contains("..")
    }

    /// A file directly inside the export folder, never outside it.
    private func libraryFile(_ name: String?) -> URL? {
        guard let name, Routes.safeName(name) else { return nil }
        let url = c.exportDir.appendingPathComponent(name)
        guard url.deletingLastPathComponent().standardizedFileURL.path == c.exportDir.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func staticFile(_ name: String) -> HTTPResponse {
        let url = webDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .text(404, "missing \(name) in \(webDir.path)") }
        var r = HTTPResponse.file(url)
        if name == "index.html" {
            r.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: blob:; media-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'"
        }
        return r
    }
}
