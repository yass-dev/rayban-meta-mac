import Foundation
import Network

/// A small HTTP/1.1 server on the loopback interface only: one request per connection, files streamed with
/// Range support (video seeking), and Server-Sent Events for live state.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    func json<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: body) }
}

enum HTTPBody {
    case data(Data)
    case file(URL)
    case events
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: HTTPBody

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"], body: .data(data))
    }

    static func ok(_ message: String = "ok") -> HTTPResponse { json(["ok": AnyEncodable(true), "message": AnyEncodable(message)]) }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["ok": AnyEncodable(false), "error": AnyEncodable(message)], status: status)
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: .data(Data(text.utf8)))
    }

    static func file(_ url: URL, type: String? = nil, cache: Bool = false) -> HTTPResponse {
        var h = ["Content-Type": type ?? HTTPServer.mime(url.pathExtension)]
        h["Cache-Control"] = cache ? "private, max-age=86400" : "no-store"
        return HTTPResponse(status: 200, headers: h, body: .file(url))
    }
}

/// Wraps any Encodable so heterogeneous dictionaries encode.
struct AnyEncodable: Encodable {
    let encode: (Encoder) throws -> Void
    // Through a container, so the encoder's own strategies (ISO 8601 dates) apply to wrapped values.
    init<T: Encodable>(_ v: T) { encode = { encoder in var c = encoder.singleValueContainer(); try c.encode(v) } }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}

extension AnyEncodable: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    init(booleanLiteral value: Bool) { self.init(value) }
    init(stringLiteral value: String) { self.init(value) }
    init(integerLiteral value: Int) { self.init(value) }
}

/// One open Server-Sent Events stream.
final class EventClient {
    let connection: NWConnection
    var alive = true
    init(_ c: NWConnection) { connection = c }

    func send(_ event: String, _ data: Data) {
        guard alive else { return }
        var chunk = Data("event: \(event)\ndata: ".utf8)
        // SSE data must not contain raw newlines: JSON from JSONEncoder has none unless pretty printed.
        chunk.append(data)
        chunk.append(Data("\n\n".utf8))
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.alive = false; self?.connection.cancel() }
        })
    }
}

final class HTTPServer {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "visor-web.http", attributes: .concurrent)
    var handler: (HTTPRequest) async -> HTTPResponse = { _ in .text(404, "not found") }
    var onEventsClient: (EventClient) -> Void = { _ in }

    init(port: UInt16) { self.port = port }

    /// Throws when the port is taken, typically by another copy of the app.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { listener.cancel(); throw failure }
        self.listener = listener
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 2_000_000 { c.cancel(); return }
            if let request = HTTPServer.parse(buffer) {
                Task { await self.serve(request, on: c) }
            } else if done || error != nil {
                c.cancel()
            } else {
                self.read(c, buffer: buffer)
            }
        }
    }

    /// A complete request, or nil when more bytes are needed.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart ..< bodyStart + length)
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(first[0]).uppercased(), path: comps?.path ?? target, query: query, headers: headers, body: body)
    }

    private func serve(_ request: HTTPRequest, on c: NWConnection) async {
        let response = await handler(request)
        switch response.body {
        case .events:
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            head += ": hello\n\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            onEventsClient(EventClient(c))
        case .data(let data):
            write(c, status: response.status, headers: response.headers, length: data.count, extra: [:]) { send in send(data, true) }
        case .file(let url):
            sendFile(url, request: request, response: response, on: c)
        }
    }

    private func headString(_ status: Int, _ headers: [String: String]) -> String {
        var s = "HTTP/1.1 \(status) \(HTTPServer.reason(status))\r\n"
        var h = headers
        h["Connection"] = "close"
        h["X-Content-Type-Options"] = "nosniff"
        h["Referrer-Policy"] = "no-referrer"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        return s + "\r\n"
    }

    private func write(_ c: NWConnection, status: Int, headers: [String: String], length: Int, extra: [String: String], _ body: (_ send: (Data, Bool) -> Void) -> Void) {
        var h = headers.merging(extra) { $1 }
        h["Content-Length"] = "\(length)"
        c.send(content: Data(headString(status, h).utf8), completion: .contentProcessed { _ in })
        body { data, last in
            c.send(content: data, completion: .contentProcessed { _ in if last { c.cancel() } })
        }
    }

    /// The file, or the byte range the browser asked for, streamed in 1 MB chunks.
    private func sendFile(_ url: URL, request: HTTPRequest, response: HTTPResponse, on c: NWConnection) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            write(c, status: 404, headers: ["Content-Type": "text/plain"], length: 9, extra: [:]) { $0(Data("not found".utf8), true) }
            return
        }
        var start: Int64 = 0
        var end: Int64 = max(0, size - 1)
        var status = 200
        var headers = response.headers
        headers["Accept-Ranges"] = "bytes"
        if let range = request.header("range"), range.hasPrefix("bytes="), size > 0 {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
            if parts.count == 2 {
                if parts[0].isEmpty, let n = Int64(parts[1]) { start = max(0, size - n) }
                else { start = Int64(parts[0]) ?? 0; if let e = Int64(parts[1]) { end = min(e, size - 1) } }
            }
            guard start <= end, start < size else {
                try? handle.close()
                write(c, status: 416, headers: ["Content-Range": "bytes */\(size)"], length: 0, extra: [:]) { $0(Data(), true) }
                return
            }
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }
        let length = size == 0 ? 0 : end - start + 1
        headers["Content-Length"] = "\(length)"
        c.send(content: Data(headString(status, headers).utf8), completion: .contentProcessed { _ in })
        if request.method == "HEAD" || length == 0 { try? handle.close(); c.cancel(); return }
        try? handle.seek(toOffset: UInt64(start))
        var left = length
        func pump() {
            let n = Int(min(left, 1 << 20))
            guard n > 0, let chunk = try? handle.read(upToCount: n), !chunk.isEmpty else { try? handle.close(); c.cancel(); return }
            left -= Int64(chunk.count)
            c.send(content: chunk, completion: .contentProcessed { error in
                if error != nil || left <= 0 { try? handle.close(); c.cancel() } else { pump() }
            })
        }
        pump()
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
         409: "Conflict", 416: "Range Not Satisfiable", 500: "Internal Server Error"][status] ?? "Status"
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}
