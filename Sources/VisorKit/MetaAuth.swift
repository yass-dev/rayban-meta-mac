import Compression
import Foundation

public struct TokenError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// The Meta AI app's own client tokens. Not in this repository: see the README.
public struct MetaAppTokens {
    /// Starts with `HW|`. Field `access_token` on the hardware calls.
    public let hw: String
    /// Starts with `AR|`. Field `access_token` on the AR login.
    public let ar: String

    public init(hw: String, ar: String) {
        self.hw = hw
        self.ar = ar
    }
}

/// Python's `urllib.parse.quote(value, safe='')` and `quote_plus`, byte for byte.
enum PyUrl {
    static func quote(_ value: String, plusForSpace: Bool = false) -> String {
        var out = ""
        for b in value.utf8 {
            let c = Character(UnicodeScalar(b))
            if c.isASCII, c.isLetter || c.isNumber || "_.-~".contains(c) { out.append(c) }
            else if plusForSpace, c == " " { out.append("+") }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    static func encode(_ fields: [(String, String)]) -> String {
        fields.map { quote($0.0, plusForSpace: true) + "=" + quote($0.1, plusForSpace: true) }.joined(separator: "&")
    }
}

/// Python's `json.dumps(value)` with its defaults, over an order-preserving JSON value.
public indirect enum JSONValue {
    case null, bool(Bool), number(String), string(String), array([JSONValue]), object([(String, JSONValue)])

    public subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public func pyDumps() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += ", " }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, (key, value)) in pairs.enumerated() {
                if i > 0 { out += ", " }
                JSONValue.writeString(key, into: &out)
                out += ": "
                value.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for unit in value.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20 ... 0x7E: out.append(Character(UnicodeScalar(unit)!))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        out += "\""
    }

    /// A small order-preserving JSON parser.
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.utf8))
        let v = try p.value()
        p.skipWs()
        guard p.i == p.s.count else { throw TokenError("trailing data after JSON") }
        return v
    }

    private struct Parser {
        let s: [UInt8]
        var i = 0
        init(_ s: [UInt8]) { self.s = s }

        mutating func skipWs() { while i < s.count, [0x20, 0x0A, 0x0D, 0x09].contains(s[i]) { i += 1 } }

        mutating func value() throws -> JSONValue {
            skipWs()
            guard i < s.count else { throw TokenError("unexpected end of JSON") }
            switch s[i] {
            case 0x7B: // {
                i += 1
                var pairs: [(String, JSONValue)] = []
                skipWs()
                if i < s.count, s[i] == 0x7D { i += 1; return .object(pairs) }
                while true {
                    skipWs()
                    let key = try string()
                    skipWs()
                    guard i < s.count, s[i] == 0x3A else { throw TokenError("expected ':' in JSON") }
                    i += 1
                    pairs.append((key, try value()))
                    skipWs()
                    guard i < s.count else { throw TokenError("unterminated JSON object") }
                    if s[i] == 0x2C { i += 1; continue }
                    if s[i] == 0x7D { i += 1; return .object(pairs) }
                    throw TokenError("expected ',' or '}' in JSON")
                }
            case 0x5B: // [
                i += 1
                var items: [JSONValue] = []
                skipWs()
                if i < s.count, s[i] == 0x5D { i += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipWs()
                    guard i < s.count else { throw TokenError("unterminated JSON array") }
                    if s[i] == 0x2C { i += 1; continue }
                    if s[i] == 0x5D { i += 1; return .array(items) }
                    throw TokenError("expected ',' or ']' in JSON")
                }
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            default:
                let start = i
                while i < s.count, "0123456789+-.eE".utf8.contains(s[i]) { i += 1 }
                guard i > start else { throw TokenError("bad JSON value") }
                return .number(String(decoding: s[start ..< i], as: UTF8.self))
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= s.count, Array(s[i ..< i + w.count]) == w else { throw TokenError("bad JSON literal") }
            i += w.count
        }

        mutating func string() throws -> String {
            guard i < s.count, s[i] == 0x22 else { throw TokenError("expected a JSON string") }
            i += 1
            var units: [UInt16] = []
            while i < s.count {
                let c = s[i]
                i += 1
                if c == 0x22 { return String(utf16CodeUnits: units, count: units.count) }
                if c == 0x5C {
                    guard i < s.count else { break }
                    let e = s[i]
                    i += 1
                    switch e {
                    case 0x22: units.append(0x22)
                    case 0x5C: units.append(0x5C)
                    case 0x2F: units.append(0x2F)
                    case 0x62: units.append(0x08)
                    case 0x66: units.append(0x0C)
                    case 0x6E: units.append(0x0A)
                    case 0x72: units.append(0x0D)
                    case 0x74: units.append(0x09)
                    case 0x75:
                        guard i + 4 <= s.count, let u = UInt16(String(decoding: s[i ..< i + 4], as: UTF8.self), radix: 16) else { throw TokenError("bad \\u escape") }
                        units.append(u)
                        i += 4
                    default: throw TokenError("bad JSON escape")
                    }
                    continue
                }
                // Decode the UTF-8 sequence starting at c into UTF-16 units.
                var scalar: UInt32
                var extra: Int
                if c < 0x80 { scalar = UInt32(c); extra = 0 }
                else if c & 0xE0 == 0xC0 { scalar = UInt32(c & 0x1F); extra = 1 }
                else if c & 0xF0 == 0xE0 { scalar = UInt32(c & 0x0F); extra = 2 }
                else { scalar = UInt32(c & 0x07); extra = 3 }
                for _ in 0 ..< extra {
                    guard i < s.count else { throw TokenError("bad UTF-8 in JSON") }
                    scalar = (scalar << 6) | UInt32(s[i] & 0x3F)
                    i += 1
                }
                if let u = UnicodeScalar(scalar) { units.append(contentsOf: Array(String(Character(u)).utf16)) }
            }
            throw TokenError("unterminated JSON string")
        }
    }
}

/// One HTTP POST, and whatever came back.
public struct HttpReply {
    public let status: Int
    public let body: Data
}

public enum Http {
    public static func post(_ url: String, headers: [String: String], body: Data) async throws -> HttpReply {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return HttpReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// The Meta login: the authorize URL, the code exchange for an FRLA, and the FRLA to ARAe login.
public enum MetaLogin {
    /// Built from the same line in the Meta app that hands them to its login. All three belong to one flow.
    static let appId = "934401142814369"
    public static let redirectUri = "https://accounts.meta.com/native/oidc/redirect/metaai"
    static let authorizeUrl = "https://accounts.meta.com/oidc/"
    static let exchangeUrl = "https://api.accounts.meta.com/native/oidc/token-exchange/"
    static let arHost = "ar.graph.meta.com"
    /// The user agent both Meta auth calls send.
    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 15) [FBAN/Stella;FBAV/289.0.0.25.162;FBSN/Android;FBSV/15;FBLC/en_US]"

    public struct AuthorizeRequest {
        public let url: String
        public let state: String
    }

    public static func authorizeRequest() -> AuthorizeRequest {
        let state = Data(Random.bytes(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let query = PyUrl.encode([
            ("app_id", appId), ("scope", "openid"), ("response_type", "code"), ("redirect_uri", redirectUri), ("state", state),
        ])
        return AuthorizeRequest(url: "\(authorizeUrl)?\(query)", state: state)
    }

    /// The code and state out of the redirect URL the browser landed on.
    public static func codeFromRedirect(_ redirect: String, expectedState: String) throws -> String {
        guard let components = URLComponents(string: redirect.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TokenError("that is not a URL")
        }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw TokenError("the redirect carried no code; parameters: \(items.map(\.name))")
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw TokenError("state mismatch: that redirect belongs to another login")
        }
        return code
    }

    /// The auth code for an FRLA.
    public static func exchangeCode(_ code: String) async throws -> String {
        let body = [("mt_app_id", appId), ("oidc_auth_code", code), ("redirect_uri", redirectUri)]
            .map { "\($0.0)=\(PyUrl.quote($0.1))" }.joined(separator: "&")
        let reply = try await Http.post(exchangeUrl, headers: ["Content-Type": "application/x-www-form-urlencoded", "User-Agent": userAgent], body: Data(body.utf8))
        guard let payload = try? JSONValue.parse(String(decoding: reply.body, as: UTF8.self)) else {
            throw TokenError("token-exchange answered HTTP \(reply.status) with a non-JSON body. A 500 here means the code belongs to a different flow.")
        }
        let token = payload["access_token"]?.stringValue ?? ""
        let userId = payload["user_id"]?.stringValue ?? ""
        guard !token.isEmpty, !userId.isEmpty else {
            let problem = ["title", "status", "detail"].compactMap { k in payload[k]?.stringValue.map { "\(k)=\($0)" } }
            throw TokenError(problem.isEmpty ? "token-exchange returned no access_token/user_id pair (HTTP \(reply.status))" : "token-exchange refused the code: \(problem.joined(separator: ", "))")
        }
        return token
    }

    /// FRLA to ARAe: the AR login with the AR app token.
    public static func exchangeFrla(_ frla: String, tokens: MetaAppTokens) async throws -> String {
        let fields = [
            ("access_token", tokens.ar), ("frl_access_token", frla),
            ("logging_session_id", UUID().uuidString.lowercased()), ("device_id", UUID().uuidString.lowercased()),
            ("format", "json"), ("generate_session_cookies", "1"), ("generate_analytics_claim", "1"),
        ]
        let reply = try await Http.post("https://\(arHost)/login", headers: ["Content-Type": "application/x-www-form-urlencoded", "User-Agent": userAgent], body: Data(PyUrl.encode(fields).utf8))
        guard let payload = try? JSONValue.parse(String(decoding: reply.body, as: UTF8.self)) else {
            throw TokenError("AR login: response was not JSON (HTTP \(reply.status))")
        }
        if let error = payload["error"] {
            throw TokenError("AR login refused: \(error["message"]?.stringValue ?? error.pyDumps())")
        }
        guard let value = payload["access_token"]?.stringValue, !value.isEmpty else {
            throw TokenError("AR login: no access_token in the response")
        }
        return value
    }
}

/// `pair_request` then `pair` on Meta's hardware host. Port of `PairingBackend`.
public final class PairingBackend {
    static let graphBase = "https://graph.facebook-hardware.com"
    private let userToken: String
    private let tokens: MetaAppTokens

    public init(userToken: String, tokens: MetaAppTokens) {
        self.userToken = userToken
        self.tokens = tokens
    }

    private func common() -> [(String, String)] {
        [("access_token", tokens.hw), ("user_access_token", userToken), ("user_token_universe", "ar"), ("pair_protocol_version", "4")]
    }

    private func post(_ method: String, fields: [(String, String)], receiptKey: String) async throws -> Receipt {
        let reply = try await Http.post(
            "\(PairingBackend.graphBase)/\(method)",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Content-Encoding": "gzip"],
            body: Data(Gzip.compress(Array(PyUrl.encode(fields).utf8)))
        )
        let text = String(decoding: reply.body, as: UTF8.self)
        if reply.status >= 400 { throw ProvisioningError("\(method): HTTP \(reply.status) \(text.prefix(300))") }
        let payload = try JSONValue.parse(text)
        if let error = payload["error"] {
            throw ProvisioningError("\(method): \(error["message"]?.stringValue ?? error.pyDumps())")
        }
        guard let value = payload[receiptKey] else { throw ProvisioningError("\(method): no \(receiptKey) in the response") }
        guard let signature = payload["receipt_signature"]?.stringValue else { throw ProvisioningError("\(method): no receipt_signature in the response") }
        let body: String
        if case .string(let s) = value { body = s } else { body = value.pyDumps() }
        let sigBytes = Data(base64Encoded: signature, options: .ignoreUnknownCharacters) ?? Data()
        return Receipt(signature: sigBytes.bytes, bodyJson: Array(body.utf8))
    }

    public func pairRequest(certDer: [UInt8], serial: String, deviceNonce: [UInt8], appPubkey: [UInt8]) async throws -> Receipt {
        var fields = common()
        fields.append(("device_cert", Data(certDer).base64EncodedString()))
        fields.append(("serial_number", serial))
        let additional = JSONValue.object([
            ("device_nonce", .string(Data(deviceNonce).base64EncodedString())),
            ("app_pubkey", .string(Data(appPubkey).base64EncodedString())),
            ("secondary_cert", .string("")),
        ])
        fields.append(("additional_data", additional.pyDumps()))
        return try await post("pair_request", fields: fields, receiptKey: "pending_ownership_receipt")
    }

    public func pair(devicePending: Receipt) async throws -> Receipt {
        var fields = common()
        fields.append(("device_pending_ownership_receipt", String(decoding: devicePending.bodyJson, as: UTF8.self)))
        fields.append(("device_pending_ownership_receipt_signature", Data(devicePending.signature).base64EncodedString()))
        return try await post("pair", fields: fields, receiptKey: "final_ownership_receipt")
    }
}

/// gzip, as a wrapper around libcompression's raw deflate.
enum Gzip {
    static func compress(_ input: [UInt8]) -> [UInt8] {
        var deflated = [UInt8](repeating: 0, count: max(64, input.count + input.count / 10 + 64))
        let n = input.withUnsafeBufferPointer { src in
            deflated.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n == 0 {
            // Incompressible or tiny: a stored block by hand.
            deflated = storedDeflate(input)
        } else {
            deflated.removeSubrange(n...)
        }
        var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        out += deflated
        let crc = crc32(input)
        out += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 24) & 0xFF)]
        let size = UInt32(truncatingIfNeeded: input.count)
        out += [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)]
        return out
    }

    private static func storedDeflate(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var at = 0
        repeat {
            let n = min(65535, input.count - at)
            let last: UInt8 = at + n >= input.count ? 1 : 0
            out.append(last)
            out += [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += input[at ..< at + n]
            at += n
        } while at < input.count
        return out
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
