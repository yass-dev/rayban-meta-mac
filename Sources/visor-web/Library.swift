import AVFoundation
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VisorKit

/// The export folder on the Mac: what is in it, which files are byte-identical copies, and small JPEG
/// thumbnails (ImageIO for photos, AVFoundation for videos) so any browser can show HEIC and HEVC.
final class Library {
    struct Item: Encodable {
        let name: String
        let size: Int64
        let sizeText: String
        let date: Date
        let kind: String          // video, photo, other
        let handle6: String?      // the capture handle's first 6 characters, from the file name
        let live: Bool            // a live photo's clip
        var duplicateOf: String?  // the name of the file this one is a byte-identical copy of
    }

    private let lock = NSLock()
    private var hashes: [String: (Int64, Date, String)] = [:]  // path -> size, mtime, sha256
    let thumbs: URL
    let views: URL

    init(caches: URL) {
        thumbs = caches.appendingPathComponent("thumbs", isDirectory: true)
        views = caches.appendingPathComponent("views", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
    }

    static let pattern = try! NSRegularExpression(pattern: #"^Visor_\d{8}_\d{6}_([0-9A-Za-z]{1,12})(_live)?(\.\d+)?\.[A-Za-z0-9]+$"#)

    static func kind(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v": return "video"
        case "heic", "heif", "jpg", "jpeg", "png": return "photo"
        default: return "other"
        }
    }

    /// Every visible file in `dir`, newest first, with duplicates marked when `findDuplicates`.
    func items(in dir: URL, findDuplicates: Bool) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var items: [Item] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            let size = Int64(v.fileSize ?? 0)
            var handle6: String?
            var live = false
            if let m = Library.pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
                handle6 = Range(m.range(at: 1), in: name).map { String(name[$0]) }
                live = m.range(at: 2).location != NSNotFound
            }
            items.append(Item(name: name, size: size, sizeText: sizeWords(UInt64(size)), date: v.creationDate ?? v.contentModificationDate ?? Date(),
                              kind: Library.kind(url.pathExtension), handle6: handle6, live: live, duplicateOf: nil))
        }
        items.sort { $0.date != $1.date ? $0.date > $1.date : ($0.name.count, $0.name) < ($1.name.count, $1.name) }
        guard findDuplicates else { return items }
        // Same size first, then the full SHA-256: only then is a file a copy.
        let bySize = Dictionary(grouping: items.indices, by: { items[$0].size })
        for (_, group) in bySize where group.count > 1 {
            var firstByHash: [String: Int] = [:]
            // The original is the one with the shortest name (no ".1" suffix), then alphabetical.
            for i in group.sorted(by: { (items[$0].name.count, items[$0].name) < (items[$1].name.count, items[$1].name) }) {
                guard let h = hash(dir.appendingPathComponent(items[i].name)) else { continue }
                if let first = firstByHash[h] { items[i].duplicateOf = items[first].name } else { firstByHash[h] = i }
            }
        }
        return items
    }

    private func hash(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let size = Int64(v.fileSize ?? 0), date = v.contentModificationDate ?? .distantPast
        if let cached = lock.withLock({ hashes[url.path] }), cached.0 == size, cached.1 == date { return cached.2 }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        let hex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        lock.withLock { hashes[url.path] = (size, date, hex) }
        return hex
    }

    /// A JPEG at most `maxPixels` on its long side, made once and cached.
    func thumbnail(of url: URL, maxPixels: Int = 480) -> URL? {
        let key = cacheKey(url, suffix: "t\(maxPixels)")
        let out = thumbs.appendingPathComponent(key + ".jpg")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let image: CGImage?
        if Library.kind(url.pathExtension) == "video" {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            image = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixels]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        guard let image, writeJpeg(image, to: out, quality: 0.8) else { return nil }
        return out
    }

    /// A photo as a full-size JPEG, for browsers that cannot show HEIC.
    func viewable(_ url: URL) -> URL? {
        if ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) { return url }
        let out = views.appendingPathComponent(cacheKey(url, suffix: "v") + ".jpg")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8192]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), writeJpeg(image, to: out, quality: 0.92) else { return nil }
        return out
    }

    private func cacheKey(_ url: URL, suffix: String) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let raw = "\(url.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(suffix)"
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func writeJpeg(_ image: CGImage, to url: URL, quality: Double) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
