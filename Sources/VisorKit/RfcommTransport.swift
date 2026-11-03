import Foundation
import IOBluetooth

/// The glasses' RFCOMM service record: service class UUID and the channel it has always been on.
public enum MetaBluetooth {
    public static let rfcommServiceUuid = "8b0d2687-42a4-44cb-9436-fba3b9b96de2"
    public static let rfcommChannel: BluetoothRFCOMMChannelID = 7
    public static let companyId = 0x01AB
    public static let leServiceUuid = "0000fd5f-0000-1000-8000-00805f9b34fb"
    public static let lePsmCharacteristic = "05acbe9f-6f61-4ca9-80bf-c8bbb52991c0"
}

/// A paired pair of glasses, as the Mac's Bluetooth stack knows them.
public struct PairedGlasses {
    public let name: String
    public let address: String
    public let productId: Int
    public let connected: Bool
    public let rfcommChannel: Int?

    /// Every paired device with Meta's vendor id, or whose SDP names the Meta RFCOMM service.
    public static func all() -> [PairedGlasses] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { device in
            let channel = metaChannel(device)
            let vendorIsMeta = device.vendorID?.intValue == MetaBluetooth.companyId
            guard channel != nil || vendorIsMeta else { return nil }
            return PairedGlasses(
                name: device.name ?? "?",
                address: device.addressString ?? "?",
                productId: device.productID?.intValue ?? 0,
                connected: device.isConnected(),
                rfcommChannel: channel
            )
        }
    }

    static func metaChannel(_ device: IOBluetoothDevice) -> Int? {
        guard let services = device.services as? [IOBluetoothSDPServiceRecord] else { return nil }
        let metaUuid = IOBluetoothSDPUUID(data: Data(hexUuid: MetaBluetooth.rfcommServiceUuid))
        for record in services {
            var channel: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channel) == kIOReturnSuccess else { continue }
            if record.getServiceName() == "Meta" { return Int(channel) }
            if record.hasService(from: [metaUuid]) { return Int(channel) }
        }
        return nil
    }
}

extension Data {
    /// The 16 bytes of a UUID written as 8-4-4-4-12 hex.
    init(hexUuid: String) {
        let hex = hexUuid.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[i ..< j], radix: 16) ?? 0)
            i = j
        }
        self.init(bytes)
    }
}

private extension IOBluetoothDevice {
    var vendorID: NSNumber? { value(forKey: "vendorID") as? NSNumber }
    var productID: NSNumber? { value(forKey: "productID") as? NSNumber }
}

/// The byte pipe under AirShield over Bluetooth Classic: RFCOMM channel 7 to the bonded glasses.
/// IOBluetooth delivers its callbacks on the run loop the channel was opened from, so every call
/// into it goes through the main thread, whose run loop the command line keeps running.
public final class RfcommTransport: NSObject, Transport, IOBluetoothRFCOMMChannelDelegate {
    private let address: String
    private let channelId: BluetoothRFCOMMChannelID
    private let pipe = BytePipe()
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void, Error>?
    private var mtu = 0
    public var log: ((String) -> Void)?

    public init(address: String, channel: BluetoothRFCOMMChannelID = MetaBluetooth.rfcommChannel) {
        self.address = address
        self.channelId = channel
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [self] in
                guard let device = IOBluetoothDevice(addressString: address) else {
                    c.resume(throwing: TransportError("\(address) is not a Bluetooth address"))
                    return
                }
                if !device.isConnected() {
                    let status = device.openConnection()
                    if status != kIOReturnSuccess {
                        c.resume(throwing: TransportError("the glasses did not take a Bluetooth Classic connection (IOReturn \(status)). RFCOMM needs them awake: open the arms or take them out of the case, or try --le"))
                        return
                    }
                }
                opening = c
                var opened: IOBluetoothRFCOMMChannel?
                let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelId, delegate: self)
                if status != kIOReturnSuccess {
                    opening = nil
                    c.resume(throwing: TransportError("could not open RFCOMM channel \(channelId) (IOReturn \(status))"))
                    return
                }
                channel = opened
            }
        }
    }

    public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let c = opening else { return }
        opening = nil
        if error == kIOReturnSuccess {
            channel = rfcommChannel
            mtu = Int(rfcommChannel.getMTU())
            log?("RFCOMM channel \(channelId) open, MTU \(mtu)")
            c.resume()
        } else {
            c.resume(throwing: TransportError("RFCOMM channel \(channelId) refused (IOReturn \(error))"))
        }
    }

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        pipe.append(bytes)
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log?("RFCOMM channel closed by the glasses")
        pipe.fail(TransportError("the glasses closed the RFCOMM channel"))
        if let c = opening {
            opening = nil
            c.resume(throwing: TransportError("the RFCOMM channel closed before it opened"))
        }
    }

    public func send(_ sdu: [UInt8]) async throws {
        guard let channel else { throw TransportError("not connected") }
        let chunk = max(1, mtu > 0 ? mtu : 1011)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                var at = 0
                var buffer = sdu
                while at < buffer.count {
                    let n = min(chunk, buffer.count - at)
                    let status = buffer.withUnsafeMutableBytes { raw -> IOReturn in
                        channel.writeSync(raw.baseAddress! + at, length: UInt16(n))
                    }
                    if status != kIOReturnSuccess {
                        c.resume(throwing: TransportError("RFCOMM write failed (IOReturn \(status))"))
                        return
                    }
                    at += n
                }
                c.resume()
            }
        }
    }

    public func receive() async throws -> [UInt8] {
        try await SduReader.next(from: pipe)
    }

    public func close() {
        let channel = self.channel
        self.channel = nil
        DispatchQueue.main.async {
            channel?.close()
        }
        pipe.fail(TransportError("closed"))
    }
}
