import Foundation

/// Minimal append-only debug log at ~/Library/Application Support/ntfy-bar/debug.log.
/// Never log credentials or message bodies.
enum Log {
    private static let queue = DispatchQueue(label: "com.kudcrafts.ntfy-bar.log")

    static var url: URL { Storage.directory.appendingPathComponent("debug.log") }

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let url = self.url
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keep the log small: truncate on launch if over 512 KB.
    static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 512 * 1024 { try? FileManager.default.removeItem(at: url) }
    }
}
