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
    /// Action buttons (`view`, `http`, `copy`, `broadcast`). Optional so stored history from
    /// older builds still decodes.
    var actions: [NtfyAction]? = nil

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

    /// The actions macOS can run, in order, at most `NtfyAction.maxButtons`. Empty means the
    /// notification gets no buttons and a click just opens `openURL`, as before.
    var buttonActions: [NtfyAction] {
        Array((actions ?? []).filter(\.isSupported).prefix(NtfyAction.maxButtons))
    }
}

/// One ntfy action button, as published (https://docs.ntfy.sh/publish/#action-buttons).
struct NtfyAction: Codable, Hashable, Sendable {
    /// ntfy allows three buttons per message; Android shows three too.
    static let maxButtons = 3

    var id: String?
    let action: String
    let label: String
    var clear: Bool?
    var url: String?
    var method: String?
    var headers: [String: String]?
    var body: String?
    var value: String?

    /// `broadcast` is Android-only. `view`/`http` need an http(s) URL, `copy` a value.
    var isSupported: Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch action {
        case "view", "http": return webURL != nil
        case "copy": return value != nil
        default: return false
        }
    }

    var webURL: URL? {
        guard let url, let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }

    /// The request an `http` action sends. ntfy's default method is POST.
    var httpRequest: URLRequest? {
        guard action == "http", let url = webURL else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        let m = (method ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        req.httpMethod = m.isEmpty ? "POST" : m
        for (k, v) in headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        if let body, !["GET", "HEAD"].contains(req.httpMethod ?? "") { req.httpBody = Data(body.utf8) }
        return req
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
    let actions: [NtfyAction]?

    var asMessage: NtfyMessage? {
        guard event == "message", let id, let time, let topic else { return nil }
        return NtfyMessage(id: id, time: time, topic: topic, title: title, message: message,
                           priority: priority, tags: tags, click: click,
                           icon: icon, attachment: attachment, actions: actions)
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
    // Catalog fields (see CatalogSync). `managed` = added by the catalog, removed when it drops out.
    var managed: Bool?
    var app: String?
    var appName: String?
    var appIcon: String?
    /// Sound class: silent | default | alert | urgent | cash | done | fail | ask.
    var sound: String?
    /// Catalog topic name; nil = show the topic id.
    var displayName: String?
    var id: String { name }

    init(name: String, muted: Bool = false, enabled: Bool = true) {
        self.name = name
        self.muted = muted
        self.enabled = enabled
    }

    // Settings saved before `enabled` / the catalog fields existed must still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        managed = try c.decodeIfPresent(Bool.self, forKey: .managed)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appIcon = try c.decodeIfPresent(String.self, forKey: .appIcon)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var serverURL: String = ""
    var username: String = ""
    var topics: [TopicConfig] = []
    var soundForAll: Bool = false
    /// nil = on unless the server is ntfy.sh (see `isCatalogEnabled`).
    var catalogEnabled: Bool?
    /// The account sync topic from `/v1/catalog`; streamed, never listed.
    var syncTopic: String?
    /// nil = on. Off leaves only the mascot's badge dot in the menu bar.
    var showUnreadCount: Bool?
    /// This Mac's sound theme; nil = follow the server.
    var soundTheme: String?
    /// The `sound_theme` of the last catalog; nil from a server that predates themes.
    var serverSoundTheme: String?

    var showsUnreadCount: Bool { showUnreadCount ?? true }
    /// The theme notifications play: this Mac's override, else the server's, else `cabin`.
    var effectiveSoundTheme: SoundTheme { SoundTheme.resolve(device: soundTheme, server: serverSoundTheme) }

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

    /// Rows are rebuilt as they scroll back into view; markdown parsing is too slow to redo each time.
    nonisolated(unsafe) private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4000
        return cache
    }()

    /// Plain-text preview for list rows: markdown stripped, blank lines collapsed.
    static func preview(_ s: String) -> String {
        if let cached = previewCache.object(forKey: s as NSString) { return cached as String }
        let result = plain(s)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        previewCache.setObject(result as NSString, forKey: s as NSString)
        return result
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
