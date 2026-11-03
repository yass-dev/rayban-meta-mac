import Foundation

/// The small JPEG the glasses keep of every capture, fetched over the Bluetooth session already open.
/// The phone app does the same before it moves the full files over Wi-Fi.
public final class PreviewFetcher {
    private let session: GlassesSession
    private let directory: URL
    public var log: (String) -> Void = { _ in }
    /// One preview landed: the capture's handle and the JPEG on disk.
    public var onPreview: (String, URL) -> Void = { _, _ in }

    public init(session: GlassesSession, directory: URL) {
        self.session = session
        self.directory = directory
    }

    public func file(for handle: String) -> URL { directory.appendingPathComponent("\(handle).jpg") }

    /// Ask for the preview of every capture that has none on disk yet, and wait for them. Returns how many came.
    /// Only the asked-for previews are accepted: anything else the glasses offer on Bluetooth is dropped.
    @discardableResult
    public func fetchMissing(_ captures: [Capture], perFileSeconds: TimeInterval = 8, maxSeconds: TimeInterval = 180) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var wanted: [String: String] = [:]  // asset id -> handle
        for c in captures where c.isMedia {
            guard let p = c.preview, !FileManager.default.fileExists(atPath: file(for: c.handle).path) else { continue }
            wanted[p.id] = c.handle
        }
        guard !wanted.isEmpty else { return 0 }
        let lock = NSLock()
        var pending = wanted
        var got = 0
        let spool = directory.appendingPathComponent(".spool", isDirectory: true)
        let receiver = AirshipReceiver(spool: spool)
        receiver.accept = { offer in lock.withLock { pending[offer.uuid] != nil } }
        receiver.onReceived = { [weak self] r in
            guard let self else { return }
            let handle: String? = lock.withLock { pending.removeValue(forKey: r.offer.uuid) }
            guard let handle, r.verified else { try? FileManager.default.removeItem(at: r.file); return }
            let target = self.file(for: handle)
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.moveItem(at: r.file, to: target)) != nil {
                lock.withLock { got += 1 }
                self.onPreview(handle, target)
            }
        }
        session.addResponder(ServiceIds.airship, receiver.respond)
        defer {
            session.removeResponder(ServiceIds.airship)
            receiver.abandon()
            try? FileManager.default.removeItem(at: spool)
        }
        log("Fetching \(wanted.count) previews over Bluetooth")
        for (assetId, handle) in wanted {
            try await session.requestAsset(handle, assetId: assetId)
        }
        let started = Date()
        var lastCount = wanted.count
        var lastChange = Date()
        while true {
            let left = lock.withLock { pending.count }
            if left == 0 { break }
            if left != lastCount { lastCount = left; lastChange = Date() }
            let quietFor = Date().timeIntervalSince(max(lastChange, receiver.lastActivity))
            if quietFor > perFileSeconds * 2 || Date().timeIntervalSince(started) > maxSeconds {
                log("\(left) previews did not come")
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return lock.withLock { got }
    }
}
