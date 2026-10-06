import Foundation

/// A single ntfy message as delivered on the JSON stream (subset of fields we use).
struct NtfyMessage: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let time: Int
    let topic: String
    var title: String?
    var message: String?
    var priority: Int?
    var tags: [String]?
    var click: String?
    var icon: String?
    var attachment: NtfyAttachment?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    var effectivePriority: Int { priority ?? 3 }
    var hasTitle: Bool { !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var displayTitle: String { hasTitle ? title! : topic }
    var body: String { message ?? "" }

    /// `click` URL if present, else the first URL found in the body.
    var openURL: URL? {
        if let click, let url = URL(string: click), url.scheme != nil { return url }
        return TextUtil.firstURL(in: body)
    }

    var iconURL: URL? { icon.flatMap(URL.init(string:)).flatMap { $0.scheme == nil ? nil : $0 } }

    /// Image to show as the notification thumbnail: an image attachment wins over the icon.
    var thumbnailURL: URL? {
        if let a = attachment, a.isImage, let url = URL(string: a.url) { return url }
        return iconURL
    }
}

struct NtfyAttachment: Codable, Hashable, Sendable {
    let name: String?
    let type: String?
    let size: Int?
    let expires: Int?
    let url: String

    var isImage: Bool {
        if let type, type.hasPrefix("image/") { return true }
        let ext = (URL(string: url)?.pathExtension ?? (name ?? "")).lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"].contains(ext)
    }
}

/// Raw stream event. `open` / `keepalive` / `message` are handled; everything else ignored.
struct NtfyEvent: Decodable, Sendable {
    let event: String
    let id: String?
    let time: Int?
    let topic: String?
    let title: String?
    let message: String?
    let priority: Int?
    let tags: [String]?
    let click: String?
    let icon: String?
    let attachment: NtfyAttachment?

    var asMessage: NtfyMessage? {
        guard event == "message", let id, let time, let topic else { return nil }
        return NtfyMessage(id: id, time: time, topic: topic, title: title, message: message,
                           priority: priority, tags: tags, click: click,
                           icon: icon, attachment: attachment)
    }
}

struct Entry: Codable, Identifiable, Hashable, Sendable {
    var message: NtfyMessage
    var read: Bool
    var id: String { message.id }
}

struct TopicConfig: Codable, Hashable, Identifiable, Sendable {
    var name: String
    /// Muted: still streamed and listed, but never notifies.
    var muted: Bool = false
    /// Disabled: left out of the stream subscription entirely (history is kept).
    var enabled: Bool = true
    var id: String { name }

    init(name: String, muted: Bool = false, enabled: Bool = true) {
        self.name = name
        self.muted = muted
        self.enabled = enabled
    }

    // Settings saved before `enabled` existed must still decode (default: enabled).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var serverURL: String = ""
    var username: String = ""
    var topics: [TopicConfig] = []
    var soundForAll: Bool = false

    var topicNames: [String] { topics.map(\.name) }
    /// Topics actually subscribed to on the stream.
    var enabledTopicNames: [String] { topics.filter(\.enabled).map(\.name) }
    var isConfigured: Bool { URL(string: serverURL)?.host != nil && !enabledTopicNames.isEmpty }

    func isMuted(_ topic: String) -> Bool { topics.first { $0.name == topic }?.muted ?? false }
    /// Topics no longer in the list (removed) count as enabled so their history stays visible.
    func isEnabled(_ topic: String) -> Bool { topics.first { $0.name == topic }?.enabled ?? true }
}

enum ConnectionStatus: Equatable, Sendable {
    case notConfigured
    case connecting
    case connected
    case reconnecting(reason: String, retryAt: Date)
    case authError(retryAt: Date)

    var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .authError: "Authentication failed"
        }
    }

    var detail: String? {
        switch self {
        case .reconnecting(let reason, _): reason
        case .authError: "Check username/password or token in Settings"
        default: nil
        }
    }
}

enum TextUtil {
    static func firstURL(in s: String) -> URL? {
        guard !s.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        return detector.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.url
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(s)
    }

    /// Plain-text preview for list rows: markdown stripped, blank lines collapsed.
    static func preview(_ s: String) -> String {
        plain(s)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Rough markdown → plain text for notification bodies.
    static func plain(_ s: String) -> String {
        let stripped = s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = Substring(line)
                if l.hasPrefix("#") {
                    l = l.drop(while: { $0 == "#" })
                    if l.hasPrefix(" ") { l = l.dropFirst() }
                } else if l.hasPrefix("> ") {
                    l = l.dropFirst(2)
                }
                return String(l)
            }
            .joined(separator: "\n")
        return String(markdown(stripped).characters)
    }
}
