import CoreBluetooth
import Foundation

/// What a scan saw of one peripheral.
public struct SeenPeripheral {
    public let identifier: UUID
    public let name: String
    public let rssi: Int
    public let services: [String]
    public let manufacturerId: Int?
    public let manufacturerData: [UInt8]
    public var looksLikeMeta: Bool {
        manufacturerId == MetaBluetooth.companyId
            || services.contains { $0.uppercased().hasPrefix("FD5F") }
            || name.lowercased().contains("meta") || name.lowercased().contains("ray-ban")
    }
}

/// The byte pipe under AirShield over Bluetooth LE: an L2CAP channel on the PSM the glasses publish in
/// GATT. The glasses keep this link up while folded or charging in the case, when RFCOMM goes quiet.
/// CoreBluetooth runs on the main queue here, whose run loop the command line keeps running.
public final class LeTransport: NSObject, Transport, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    public static let defaultPsm: CBL2CAPPSM = 0x80
    static let metaService = CBUUID(string: "FD5F")
    static let psmCharacteristic = CBUUID(string: MetaBluetooth.lePsmCharacteristic)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private let pipe = BytePipe()
    private var outgoing: [UInt8] = []
    private var flushWaiters: [CheckedContinuation<Void, Error>] = []
    private var step: CheckedContinuation<Void, Error>?
    private var psm: CBL2CAPPSM?
    private let preferredIdentifier: UUID?
    private let scanSeconds: TimeInterval
    public var log: ((String) -> Void)?
    /// Every peripheral the scan saw, for `le-scan`.
    public private(set) var seen: [UUID: SeenPeripheral] = [:]
    private var scanOnly = false
    private var done = false
    private var psmCharacteristicRef: CBCharacteristic?
    private var psmReadDeadline = Date.distantFuture
    private var l2capAttempts = 0
    /// From the first connection until the PSM is read: disconnects reconnect instead of failing.
    private var pairingPhase = false
    private var reconnecting = false
    private var openingPsm: CBL2CAPPSM = 0x80
    /// The identifier CoreBluetooth gave the glasses. Kept by the caller: once the LE bond exists,
    /// the glasses can be reached by it without pairing mode.
    public private(set) var peripheralIdentifier: UUID?

    public init(identifier: UUID? = nil, scanSeconds: TimeInterval = 15) {
        preferredIdentifier = identifier
        self.scanSeconds = scanSeconds
        super.init()
    }

    // MARK: Transport

    public func connect() async throws {
        try await onMain { self.central = CBCentralManager(delegate: self, queue: .main) ; try await self.waitStep("Bluetooth LE powered on") }
        let found = try await findPeripheral()
        peripheral = found
        peripheralIdentifier = found.identifier
        found.delegate = self
        log?("LE connecting to \(found.name ?? "?") \(found.identifier)")
        try await onMain { self.central.connect(found, options: nil); try await self.waitStep("LE connection", timeout: 120) }
        log?("LE connected, discovering the Meta service")
        psmReadDeadline = Date().addingTimeInterval(170)
        pairingPhase = true
        try await onMain { found.discoverServices([LeTransport.metaService]); try await self.waitStep("the PSM characteristic (accept the pairing popup on the Mac)", timeout: 180) }
        pairingPhase = false
        let psm = self.psm ?? LeTransport.defaultPsm
        openingPsm = psm
        l2capAttempts = 0
        log?("opening L2CAP channel on PSM \(psm)")
        try await onMain { found.openL2CAPChannel(psm); try await self.waitStep("the L2CAP channel", timeout: 90) }
        log?("L2CAP channel open")
    }

    /// Scan only, for the `le-scan` command: what is around for `scanSeconds`.
    public func scan() async throws -> [SeenPeripheral] {
        scanOnly = true
        try await onMain { self.central = CBCentralManager(delegate: self, queue: .main); try await self.waitStep("Bluetooth LE powered on") }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try await Task.sleep(nanoseconds: UInt64(scanSeconds * 1_000_000_000))
        central.stopScan()
        return seen.values.sorted { $0.rssi > $1.rssi }
    }

    private func findPeripheral() async throws -> CBPeripheral {
        if let id = preferredIdentifier, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            return p
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [LeTransport.metaService])
        if let p = connected.first {
            log?("the system already holds an LE link to \(p.name ?? p.identifier.uuidString)")
            return p
        }
        log?("scanning for the glasses over LE (\(Int(scanSeconds)) s)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let deadline = Date().addingTimeInterval(scanSeconds)
        defer { central.stopScan() }
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
            if done { throw TransportError("closed") }
            if let hit = seen.values.first(where: { $0.looksLikeMeta }), let p = central.retrievePeripherals(withIdentifiers: [hit.identifier]).first {
                log?("found \(hit.name) rssi \(hit.rssi) services \(hit.services) manufacturer \(hit.manufacturerId.map { String(format: "0x%04x", $0) } ?? "-")")
                return p
            }
        }
        throw TransportError("no Meta glasses seen over LE in \(Int(scanSeconds)) s. Bonded glasses advertise only to their phone: open them, or put them in pairing mode")
    }

    public func send(_ sdu: [UInt8]) async throws {
        guard channel != nil else { throw TransportError("not connected") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.outgoing += sdu
                self.flushWaiters.append(c)
                self.flush()
            }
        }
    }

    public func receive() async throws -> [UInt8] {
        try await SduReader.next(from: pipe)
    }

    public func close() {
        done = true
        DispatchQueue.main.async {
            // A connect still in progress gives up now instead of waiting for its step's timeout.
            self.finishStep(TransportError("closed"))
            self.channel?.inputStream.close()
            self.channel?.outputStream.close()
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
        }
        pipe.fail(TransportError("closed"))
    }

    // MARK: steps

    private func onMain(_ body: @escaping () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                Task { @MainActor in
                    do { try await body(); c.resume() } catch { c.resume(throwing: error) }
                }
            }
        }
    }

    private func waitStep(_ what: String, timeout: TimeInterval = 15) async throws {
        guard try await withDeadline(timeout, {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if self.done { c.resume(throwing: TransportError("closed")) } else { self.step = c }
                }
            } onCancel: {
                DispatchQueue.main.async { self.finishStep(CancellationError()) }
            }
        }) != nil else {
            step = nil
            throw TransportError("timed out waiting for \(what)")
        }
    }

    private func finishStep(_ error: Error? = nil) {
        guard let c = step else { return }
        step = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: finishStep()
        case .unauthorized: finishStep(TransportError("this app may not use Bluetooth: allow it in System Settings > Privacy & Security > Bluetooth"))
        case .poweredOff: finishStep(TransportError("Bluetooth is off"))
        case .unsupported: finishStep(TransportError("no Bluetooth LE on this Mac"))
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.bytes ?? []
        let manufacturerId = manufacturer.count >= 2 ? Int(manufacturer[0]) | (Int(manufacturer[1]) << 8) : nil
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        seen[peripheral.identifier] = SeenPeripheral(identifier: peripheral.identifier, name: name, rssi: RSSI.intValue, services: services, manufacturerId: manufacturerId, manufacturerData: Array(manufacturer.dropFirst(2)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if reconnecting {
            reconnecting = false
            log?("LE reconnected, reading the PSM again")
            peripheral.discoverServices([LeTransport.metaService])
            return
        }
        finishStep()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishStep(TransportError("LE connect failed: \(error?.localizedDescription ?? "?")"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log?("LE disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if pairingPhase, !done, Date() < psmReadDeadline {
            reconnecting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.done else { return }
                self.log?("reconnecting over LE")
                central.connect(peripheral, options: nil)
            }
            return
        }
        finishStep(TransportError("LE disconnected"))
        pipe.fail(TransportError("the LE link dropped"))
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == LeTransport.metaService }) else {
            log?("no Meta GATT service (\(error?.localizedDescription ?? "none advertised")), using PSM \(LeTransport.defaultPsm)")
            finishStep()
            return
        }
        peripheral.discoverCharacteristics([LeTransport.psmCharacteristic], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == LeTransport.psmCharacteristic }) else {
            log?("no PSM characteristic, using PSM \(LeTransport.defaultPsm)")
            finishStep()
            return
        }
        psmCharacteristicRef = c
        peripheral.readValue(for: c)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == LeTransport.psmCharacteristic else { return }
        if let error {
            let ns = error as NSError
            let needsPairing = ns.domain == CBATTErrorDomain && (ns.code == CBATTError.insufficientEncryption.rawValue || ns.code == CBATTError.insufficientAuthentication.rawValue)
            if needsPairing, Date() < psmReadDeadline {
                log?("PSM read needs an encrypted link: waiting for the LE pairing (click \"Se connecter\" on the Mac), retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let c = self.psmCharacteristicRef else { return }
                    peripheral.readValue(for: c)
                }
                return
            }
            log?("PSM read failed: \(error.localizedDescription)")
        }
        if let value = characteristic.value?.bytes, let parsed = LeTransport.parsePsm(value) {
            psm = parsed
            log?("PSM characteristic \(value.hex) -> \(parsed)")
        }
        finishStep()
    }

    /// 16-bit little-endian words; the channel's PSM is the first in the LE dynamic range, else the first fixed one.
    static func parsePsm(_ value: [UInt8]) -> CBL2CAPPSM? {
        let words = stride(from: 0, to: value.count - 1, by: 2).map { Int(value[$0]) | (Int(value[$0 + 1]) << 8) }
        return (words.first { (0x80 ... 0xFF).contains($0) } ?? words.first { (0x01 ... 0x7F).contains($0) }).map { CBL2CAPPSM($0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else {
            l2capAttempts += 1
            if l2capAttempts < 12 {
                log?("L2CAP open failed (\(error?.localizedDescription ?? "?")), retry \(l2capAttempts) in 3 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    peripheral.openL2CAPChannel(self.openingPsm)
                }
                return
            }
            finishStep(TransportError("the glasses did not open L2CAP: \(error?.localizedDescription ?? "?")"))
            return
        }
        self.channel = channel
        channel.inputStream.delegate = self
        channel.outputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .default)
        channel.outputStream.schedule(in: .main, forMode: .default)
        channel.inputStream.open()
        channel.outputStream.open()
        finishStep()
    }

    // MARK: StreamDelegate

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if aStream === channel?.inputStream {
            switch eventCode {
            case .hasBytesAvailable:
                var buffer = [UInt8](repeating: 0, count: 4096)
                while let input = channel?.inputStream, input.hasBytesAvailable {
                    let n = input.read(&buffer, maxLength: buffer.count)
                    if n > 0 { pipe.append(Array(buffer[0 ..< n])) } else { break }
                }
            case .endEncountered, .errorOccurred:
                if !done { log?("L2CAP input \(eventCode == .endEncountered ? "ended" : "failed")") }
                pipe.fail(TransportError("the L2CAP channel closed"))
            default: break
            }
        } else if aStream === channel?.outputStream {
            switch eventCode {
            case .hasSpaceAvailable: flush()
            case .endEncountered, .errorOccurred:
                let waiters = flushWaiters
                flushWaiters = []
                for w in waiters { w.resume(throwing: TransportError("the L2CAP channel closed")) }
            default: break
            }
        }
    }

    private func flush() {
        guard let output = channel?.outputStream else { return }
        while !outgoing.isEmpty, output.hasSpaceAvailable {
            let n = outgoing.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if n <= 0 { break }
            outgoing.removeFirst(n)
        }
        if outgoing.isEmpty {
            let waiters = flushWaiters
            flushWaiters = []
            for w in waiters { w.resume() }
        }
    }
}
