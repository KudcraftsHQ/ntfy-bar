import AppKit
import CryptoKit
import Foundation

/// Disk cache for message icons / image attachments under ~/Library/Caches/ntfy-bar/.
/// Every fetch is bounded (~5s) and failure just means "no image".
enum IconCache {
    static let timeout: TimeInterval = 5
    private static let maxBytes = 10 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ntfy-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Cached file for `url` if it was downloaded before.
    static func cachedFile(for url: URL) -> URL? {
        let prefix = key(url)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.first { $0.hasPrefix(prefix + ".") }.map { directory.appendingPathComponent($0) }
    }

    /// Returns a cached file, downloading it first if needed. `authorization` is only sent when
    /// the caller decided the URL is on the ntfy server.
    static func file(for url: URL, authorization: String?) async -> URL? {
        if let cached = cachedFile(for: url) { return cached }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty, data.count <= maxBytes, NSImage(data: data) != nil
            else {
                Log.write("icon: fetch failed for host \(url.host ?? "?")")
                return nil
            }
            let ext = fileExtension(url: url, mime: http.mimeType)
            let dest = directory.appendingPathComponent("\(key(url)).\(ext)")
            try data.write(to: dest, options: .atomic)
            Log.write("icon: cached \(dest.lastPathComponent) (\(data.count) bytes)")
            return dest
        } catch {
            Log.write("icon: fetch error for host \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    private static func fileExtension(url: URL, mime: String?) -> String {
        switch mime?.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? "png" : ext
        }
    }

    /// A fresh copy for UNNotificationAttachment, which moves the file it is given.
    static func temporaryCopy(of file: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntfy-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        do {
            try FileManager.default.copyItem(at: file, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

/// In-memory NSImage cache for popover rows, on top of the disk cache.
@MainActor
final class IconImageStore {
    static let shared = IconImageStore()
    private var images: [URL: NSImage] = [:]
    private var failed: Set<URL> = []

    func cached(_ url: URL) -> NSImage? { images[url] }

    func insert(_ image: NSImage, for url: URL) { images[url] = image }

    func load(_ url: URL, authorization: String?) async -> NSImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        guard let file = await IconCache.file(for: url, authorization: authorization),
              let image = NSImage(contentsOf: file) else {
            failed.insert(url)
            return nil
        }
        images[url] = image
        return image
    }
}
