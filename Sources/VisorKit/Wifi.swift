import Foundation

/// svc10, ATC LinkManager2: the glasses host a network of their own, and the Mac joins it. Port of `Wifi.kt`.
public enum AtcMsg {
    public static let createSoftAp = 0x1000
    public static let softApInfo = 0x1001
    public static let destroySoftAp = 0x1002
    public static let joinAccessPoint = 0x1010
    public static let joinAccessPointResult = 0x1011
    public static let leaveAccessPoint = 0x1012
}

public struct WifiError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// SoftApNetworkInfo: 1 status, 2 addresses (NetworkAddress, the text in 3), 3 credentials {1 ssid, 2 password}, 4 port.
public struct SoftApInfo: CustomStringConvertible {
    public let status: Int
    public let address: String?
    public let port: Int
    public let ssid: String
    public let password: String

    static let statusNames = ["UNKNOWN", "SUCCESS", "INTERNAL_ERROR", "START_AP_FAILED", "GET_IP_FAILED"]
    public var ok: Bool { status == 1 && !(address ?? "").isEmpty && !ssid.isEmpty }
    public var statusName: String { status >= 0 && status < SoftApInfo.statusNames.count ? SoftApInfo.statusNames[status] : "status \(status)" }
    public var description: String { "\(statusName), \(address ?? "no address"):\(port), ssid \(ssid)" }

    /// Where the glasses listen on every network they are on, when they leave the port out.
    public static let defaultPort = 20203

    public static func parse(_ payload: [UInt8], ssid: String, password: String) -> SoftApInfo {
        let f = Wire.parseLenient(payload)
        let address = f.repeatedBytes(2).map { Wire.parseLenient($0).string(3) }.first { !$0.isEmpty }
            .map { String($0.split(separator: "/").first ?? "") }
        let credentials = f.repeatedBytes(3).first.map(Wire.parseLenient)
        let theirSsid = credentials?.string(1) ?? ""
        let theirPassword = credentials?.string(2) ?? ""
        let port = Int(f.varint(4))
        return SoftApInfo(
            status: Int(f.varint(1)), address: address, port: port > 0 ? port : defaultPort,
            ssid: theirSsid.isEmpty ? ssid : theirSsid, password: theirPassword.isEmpty ? password : theirPassword
        )
    }
}

extension GlassesSession {
    /// CreateSoftApNetwork: the glasses host a 2.4 GHz network on channel 6 at 20 MHz, and answer with where to find it.
    public func createSoftAp(ssid: String, password: String, country: String, timeout: TimeInterval = 45) async throws -> SoftApInfo {
        let credentials = Wire.fieldString(1, ssid) + Wire.fieldString(2, password)
        let payload = Wire.fieldVarintOmitZero(3, 1) + Wire.fieldVarintOmitZero(4, 6) + Wire.fieldString(6, country)
            + Wire.fieldBytes(7, LinkUuid.random()) + Wire.fieldBytes(8, credentials) + Wire.fieldVarintOmitZero(9, 1)
        let answer = try await request(service: ServiceIds.atcLinkManager, type: AtcMsg.createSoftAp, payload: payload, expect: [AtcMsg.softApInfo], timeout: timeout)
        return SoftApInfo.parse(answer.payload, ssid: ssid, password: password)
    }

    /// DestroySoftApNetwork closes the glasses' network. They also close it on their own soon after the session ends.
    public func destroySoftAp() async throws {
        try await send(service: ServiceIds.atcLinkManager, type: AtcMsg.destroySoftAp)
    }
}

/// The Mac's Wi-Fi, driven through `networksetup` and `ipconfig`: no entitlement, no location prompt.
public enum MacWifi {
    public static func interface() -> String {
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var lines = out.split(separator: "\n").map(String.init)
        while !lines.isEmpty {
            let line = lines.removeFirst()
            if line.hasPrefix("Hardware Port: Wi-Fi"), let device = lines.first, device.hasPrefix("Device: ") {
                return String(device.dropFirst("Device: ".count))
            }
        }
        return "en0"
    }

    /// The SSID the Mac is on, or nil.
    public static func currentSsid(_ iface: String) -> String? {
        let summary = run("/usr/sbin/ipconfig", ["getsummary", iface])
        for line in summary.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SSID : ") {
                let ssid = String(t.dropFirst("SSID : ".count))
                // Recent macOS hides the name from processes without location access.
                return ssid.isEmpty || ssid.contains("redacted") ? nil : ssid
            }
        }
        return nil
    }

    public static func address(_ iface: String) -> String? {
        let out = run("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Join `ssid`, then wait until the interface has an address. A network that just came up may not be in
    /// the Mac's scan results yet, so "Could not find network" is retried for a while.
    /// When macOS hides the network name, being in the glasses' subnet (`peer`, their address) counts as joined.
    public static func join(_ iface: String, ssid: String, password: String, peer: String? = nil, timeout: TimeInterval = 75, log: (String) -> Void) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = ""
        var asked = false
        while Date() < deadline {
            if let addr = address(iface), !addr.hasPrefix("169.254") {
                let name = currentSsid(iface)
                if name == ssid || (name == nil && peer.map { sameSubnet(addr, $0) } == true) {
                    log("joined \(ssid) as \(addr)")
                    return
                }
            }
            if !asked || !lastError.isEmpty {
                let out = run("/usr/sbin/networksetup", ["-setairportnetwork", iface, ssid, password]).trimmingCharacters(in: .whitespacesAndNewlines)
                asked = true
                if out.isEmpty {
                    lastError = ""
                } else if out != lastError {
                    log("networksetup: \(out)")
                    lastError = out
                } else {
                    lastError = out
                }
                if !out.isEmpty { Thread.sleep(forTimeInterval: 3); continue }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw WifiError("the Mac could not join \(ssid)\(lastError.isEmpty ? "" : ": \(lastError)")")
    }

    static func sameSubnet(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        return x.count == 4 && y.count == 4 && x.prefix(3) == y.prefix(3)
    }

    /// Back to the network the Mac was on. macOS usually does this by itself once the glasses' network goes.
    public static func rejoin(_ iface: String, ssid: String, log: (String) -> Void) {
        let deadline = Date().addingTimeInterval(45)
        var tries = 0
        while Date() < deadline {
            if currentSsid(iface) == ssid, address(iface) != nil {
                log("back on \(ssid)")
                return
            }
            if tries % 4 == 0 {
                let out = run("/usr/sbin/networksetup", ["-setairportnetwork", iface, ssid]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { log("rejoining \(ssid): \(out)") }
            }
            tries += 1
            Thread.sleep(forTimeInterval: 1.5)
        }
        log("the Mac is not back on \(ssid) yet; macOS usually rejoins it by itself")
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "could not run \(path): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
