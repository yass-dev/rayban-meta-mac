import Foundation

/// Where this client keeps its state: the owner key, the Meta login, which glasses it owns.
public final class Store {
    public let directory: URL

    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? base.appendingPathComponent("visor-mac", isDirectory: true)
    }

    private var ownerKeyFile: URL { directory.appendingPathComponent("owner_key.pem") }
    private var frlaFile: URL { directory.appendingPathComponent("meta_login.txt") }
    private var bundleFile: URL { directory.appendingPathComponent("glasses.json") }
    private var tokensFile: URL { directory.appendingPathComponent("tokens.json") }
    private var leIdFile: URL { directory.appendingPathComponent("le_identifier.txt") }

    /// The CoreBluetooth identifier of the glasses, once an LE connection has seen them.
    public func leIdentifier() -> UUID? {
        (try? String(contentsOf: leIdFile, encoding: .utf8)).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func saveLeIdentifier(_ id: UUID) {
        try? writePrivate(Data(id.uuidString.utf8), to: leIdFile)
    }

    public struct Bundle: Codable {
        public var serial: String
        public var userId: String
        public var address: String
        public var pairedAt: Date

        public init(serial: String, userId: String, address: String, pairedAt: Date) {
            self.serial = serial
            self.userId = userId
            self.address = address
            self.pairedAt = pairedAt
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: owner key

    public func ownerKey() throws -> OwnerKey? {
        guard FileManager.default.fileExists(atPath: ownerKeyFile.path) else { return nil }
        return try OwnerKey(pem: String(contentsOf: ownerKeyFile, encoding: .utf8))
    }

    /// The stored owner key, or a new one written for the first time.
    public func ownerKeyOrNew() throws -> OwnerKey {
        if let key = try ownerKey() { return key }
        let key = OwnerKey()
        try writePrivate(Data(key.pem.utf8), to: ownerKeyFile)
        return key
    }

    // MARK: Meta login

    public func frla() -> String? {
        (try? String(contentsOf: frlaFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func saveFrla(_ value: String) throws { try writePrivate(Data(value.utf8), to: frlaFile) }

    public func forgetLogin() { try? FileManager.default.removeItem(at: frlaFile) }

    // MARK: tokens

    /// From the environment first, then tokens.json: {"hw": "HW|...", "ar": "AR|..."}.
    public func tokens() -> MetaAppTokens? {
        let env = ProcessInfo.processInfo.environment
        var hw = env["VISOR_META_HW_TOKEN"] ?? ""
        var ar = env["VISOR_META_AR_TOKEN"] ?? ""
        if hw.isEmpty || ar.isEmpty, let data = try? Data(contentsOf: tokensFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            if hw.isEmpty { hw = json["hw"] ?? "" }
            if ar.isEmpty { ar = json["ar"] ?? "" }
        }
        guard !hw.isEmpty, !ar.isEmpty else { return nil }
        return MetaAppTokens(hw: hw, ar: ar)
    }

    public func saveTokens(_ tokens: MetaAppTokens) throws {
        let data = try JSONSerialization.data(withJSONObject: ["hw": tokens.hw, "ar": tokens.ar], options: [.prettyPrinted, .sortedKeys])
        try writePrivate(data, to: tokensFile)
    }

    // MARK: glasses

    public func bundle() -> Bundle? {
        guard let data = try? Data(contentsOf: bundleFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Bundle.self, from: data)
    }

    public func saveBundle(_ bundle: Bundle) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(bundle), to: bundleFile)
    }

    // MARK: what this Mac already imported

    private var importedFile: URL { directory.appendingPathComponent("imported.json") }

    /// Capture handle -> the file names an import saved for it.
    public func imported() -> [String: [String]] {
        guard let data = try? Data(contentsOf: importedFile) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    public func markImported(_ handle: String, files: [String]) {
        var all = imported()
        all[handle] = files
        if let data = try? JSONEncoder().encode(all) { try? writePrivate(data, to: importedFile) }
    }

    // MARK: where imports go

    /// ~/Pictures/Ray-Ban Meta, unless the app's preferences say otherwise.
    public static var defaultExportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Ray-Ban Meta", isDirectory: true)
    }

    /// The folder chosen in the app (`exportDir` in web_prefs.json), else the default.
    public func exportDirectory() -> URL {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("web_prefs.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dir = json["exportDir"] as? String, !dir.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Store.defaultExportDirectory
    }

    // MARK: any small Codable value, such as the web UI's preferences

    public func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T, name: String) {
        if let data = try? JSONEncoder().encode(value) { try? writePrivate(data, to: directory.appendingPathComponent(name)) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
