import Foundation

// Kudcrafts catalog (spec §8, contract §14). Foundation only — no AppKit — so everything here
// is unit-testable: decoding, reconcile, sound mapping, sync-signal detection, request building.

/// `GET /v1/catalog` — the signed-in user's view of every app/topic they can read.
struct Catalog: Decodable, Equatable, Sendable {
    var version: Int64
    var baseURL: String?
    var historyDays: Int?
    var syncTopic: String?
    var apps: [AppEntry]

    struct AppEntry: Decodable, Equatable, Sendable {
        var id: String
        var name: String
        /// `""` from the server becomes `nil`.
        var icon: String?
        var sound: String?
        var topics: [TopicEntry]

        enum CodingKeys: String, CodingKey { case id, name, icon, sound, topics }

        init(id: String, name: String, icon: String? = nil, sound: String? = nil, topics: [TopicEntry]) {
            self.id = id
            self.name = name
            self.icon = icon
            self.sound = sound
            self.topics = topics
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            icon = (try c.decodeIfPresent(String.self, forKey: .icon)).flatMap { $0.isEmpty ? nil : $0 }
            sound = try c.decodeIfPresent(String.self, forKey: .sound)
            topics = try c.decodeIfPresent([TopicEntry].self, forKey: .topics) ?? []
        }
    }

    struct TopicEntry: Decodable, Equatable, Sendable {
        var topic: String
        /// `""` from the server becomes `nil` (= show the topic id).
        var name: String?
        /// Already resolved by the server (topic override or app default).
        var sound: String?
        var permission: String?

        enum CodingKeys: String, CodingKey { case topic, name, sound, permission }

        init(topic: String, name: String? = nil, sound: String? = nil, permission: String? = nil) {
            self.topic = topic
            self.name = name
            self.sound = sound
            self.permission = permission
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            topic = try c.decode(String.self, forKey: .topic)
            name = (try c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0.isEmpty ? nil : $0 }
            sound = try c.decodeIfPresent(String.self, forKey: .sound)
            permission = try c.decodeIfPresent(String.self, forKey: .permission)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, apps
        case baseURL = "base_url"
        case historyDays = "history_days"
        case syncTopic = "sync_topic"
    }

    init(version: Int64 = 0, baseURL: String? = nil, historyDays: Int? = nil, syncTopic: String? = nil, apps: [AppEntry]) {
        self.version = version
        self.baseURL = baseURL
        self.historyDays = historyDays
        self.syncTopic = syncTopic
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int64.self, forKey: .version) ?? 0
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays)
        syncTopic = (try c.decodeIfPresent(String.self, forKey: .syncTopic)).flatMap { $0.isEmpty ? nil : $0 }
        apps = try c.decodeIfPresent([AppEntry].self, forKey: .apps) ?? []
    }
}

/// The four portable sound classes (spec D9).
enum SoundClass: String, CaseIterable, Sendable {
    case silent, `default`, alert, urgent

    /// Bundled file under `Contents/Resources`, for the classes that have one.
    var fileName: String? {
        switch self {
        case .alert: "kc_alert.caf"
        case .urgent: "kc_urgent.caf"
        case .silent, .default: nil
        }
    }
}

enum NotificationSoundChoice: Equatable, Sendable {
    case off
    case system
    case named(String)
}

enum CatalogSync {
    // MARK: Requests

    /// Catalog calls are short request/response; never share the stream's long-lived session.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    enum FetchError: Error, Equatable, CustomStringConvertible {
        case unauthorized(Int)
        /// 404: the server has no catalog (`enable-catalog` off, or stock ntfy).
        case disabled
        case http(Int)
        case badResponse

        var description: String {
            switch self {
            case .unauthorized(let c): "Not authorized (HTTP \(c))"
            case .disabled: "This server has no catalog"
            case .http(let c): "Server returned HTTP \(c)"
            case .badResponse: "Unexpected response from server"
            }
        }
    }

    /// `https://host/` → `https://host`; nil when there is no host.
    static func normalizedBase(_ server: String) -> String? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard URL(string: base)?.host != nil else { return nil }
        return base
    }

    static func catalogRequest(base: String, auth: String, etag: String?) -> URLRequest? {
        guard let url = URL(string: "\(base)/v1/catalog") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// Returns `(nil, etag)` on 304. Only a 200 yields a catalog — the only case that may reconcile.
    static func fetch(base: String, auth: String, etag: String?, session: URLSession) async throws -> (Catalog?, String?) {
        guard let request = catalogRequest(base: base, auth: auth, etag: etag) else { throw FetchError.badResponse }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        switch http.statusCode {
        case 200:
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            return (catalog, http.value(forHTTPHeaderField: "ETag"))
        case 304: return (nil, etag)
        case 401, 403: throw FetchError.unauthorized(http.statusCode)
        case 404: throw FetchError.disabled
        default: throw FetchError.http(http.statusCode)
        }
    }

    /// `POST /v1/account/token` with Basic auth → a `tk_…` token.
    static func mintToken(base: String, username: String, password: String, label: String,
                          session: URLSession) async throws -> String {
        guard let url = URL(string: "\(base)/v1/account/token") else { throw FetchError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = tokenRequestBody(label: label)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard let token = parseToken(data) else { throw FetchError.badResponse }
        return token
    }

    /// `expires: 0` = never. Without it the server defaults to 72 h and the Mac goes dark on day 3.
    /// The token is per device and revocable in the web app (Account › Access tokens).
    static func tokenRequestBody(label: String) -> Data {
        Data(#"{"label":\#(jsonString(label)),"expires":0}"#.utf8)
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func parseToken(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, token.hasPrefix("tk_") else { return nil }
        return token
    }

    /// `ntfy-bar-<host>`: the label shown in the web app's Account → Tokens.
    static func tokenLabel(hostName: String?) -> String {
        var host = (hostName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if host.lowercased().hasSuffix(".local") { host.removeLast(6) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        var cleaned = String(host.map { allowed.contains($0) ? $0 : "-" })
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if cleaned.isEmpty { cleaned = "mac" }
        return "ntfy-bar-" + String(cleaned.prefix(40))
    }

    /// History for topics that just appeared: `GET /{a,b}/json?poll=1&since=7d`.
    static func backfillURL(base: String, topics: [String], since: String = "7d") -> URL? {
        guard !topics.isEmpty else { return nil }
        var comps = URLComponents(string: "\(base)/\(topics.joined(separator: ","))/json")
        comps?.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since)]
        return comps?.url
    }

    static func poll(url: URL, auth: String, session: URLSession) async throws -> [NtfyMessage] {
        var request = URLRequest(url: url)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        return parseMessages(data)
    }

    /// Newline-delimited JSON events → messages (non-message events and bad lines skipped).
    static func parseMessages(_ data: Data) -> [NtfyMessage] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            (try? decoder.decode(NtfyEvent.self, from: Data(line)))?.asMessage
        }
    }

    // MARK: Reconcile (contract §14.5)

    /// Pure. Adds missing catalog topics as managed (enabled, unmuted); refreshes catalog fields
    /// on topics already present while keeping the user's mute/enable; drops managed topics the
    /// catalog no longer lists; leaves topics the catalog doesn't know exactly as they are.
    /// Existing order is kept; new topics are appended in catalog order (app name, then topic).
    static func reconcile(current: [TopicConfig], catalog: Catalog) -> [TopicConfig] {
        var listed: [String: (Catalog.AppEntry, Catalog.TopicEntry)] = [:]
        var order: [String] = []
        for app in catalog.apps {
            for topic in app.topics where listed[topic.topic] == nil {
                listed[topic.topic] = (app, topic)
                order.append(topic.topic)
            }
        }

        var result: [TopicConfig] = []
        var present = Set<String>()
        for var config in current {
            if let entry = listed[config.name] {
                apply(app: entry.0, topic: entry.1, to: &config)
                result.append(config)
                present.insert(config.name)
            } else if config.managed == true {
                continue
            } else {
                // Not (or no longer) in the catalog: the user's own topic, without catalog metadata.
                clearCatalogFields(&config)
                result.append(config)
                present.insert(config.name)
            }
        }
        for name in order where !present.contains(name) {
            guard let entry = listed[name] else { continue }
            var config = TopicConfig(name: name, muted: false, enabled: true)
            config.managed = true
            apply(app: entry.0, topic: entry.1, to: &config)
            result.append(config)
            present.insert(name)
        }
        return result
    }

    private static func apply(app: Catalog.AppEntry, topic: Catalog.TopicEntry, to config: inout TopicConfig) {
        config.app = app.id
        config.appName = app.name
        config.appIcon = app.icon
        config.sound = normalizedSound(topic.sound ?? app.sound)
        config.displayName = topic.name.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func clearCatalogFields(_ config: inout TopicConfig) {
        config.app = nil
        config.appName = nil
        config.appIcon = nil
        config.sound = nil
        config.displayName = nil
    }

    /// Unknown or missing classes become `default`, so every catalog topic has a playable class.
    static func normalizedSound(_ raw: String?) -> String {
        raw.flatMap(SoundClass.init(rawValue:))?.rawValue ?? SoundClass.default.rawValue
    }

    // MARK: Sync signal

    /// True for a message body of `{"event":"sync", …}` on the account sync topic.
    static func isSyncSignal(_ body: String?) -> Bool {
        guard let body, let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["event"] as? String == "sync"
    }

    // MARK: Sounds (spec §8.6)

    /// `soundClass == nil` (or unknown) means the catalog doesn't know the topic: the legacy rule
    /// applies (sound for priority 4–5, or for everything with "Play sound for every message").
    /// Catalog topics follow their class; priority 1–2 stays quiet (same as Android's `-low` channels).
    static func soundChoice(soundClass: String?, soundForAll: Bool, priority: Int)
        -> (sound: NotificationSoundChoice, timeSensitive: Bool) {
        guard let raw = soundClass, let cls = SoundClass(rawValue: raw) else {
            return (soundForAll || priority >= 4 ? .system : .off, false)
        }
        if priority <= 2 { return (.off, false) }
        switch cls {
        case .silent: return (.off, false)
        case .default: return (.system, false)
        case .alert: return (.named(cls.fileName!), false)
        case .urgent: return (.named(cls.fileName!), true)
        }
    }
}

/// A run of chips that share a catalog app (`label == nil`: topics the catalog doesn't know).
struct TopicGroup: Identifiable, Equatable, Sendable {
    var label: String?
    var icon: String?
    var topics: [String]
    var id: String { label ?? "" }
}

extension AppSettings {
    func topic(_ name: String) -> TopicConfig? { topics.first { $0.name == name } }

    /// Display name precedence (contract §14.7): catalog topic name → topic id.
    func label(for name: String) -> String { topic(name)?.displayName ?? name }

    /// Catalog sync is on unless switched off; by default only for self-hosted servers.
    var isCatalogEnabled: Bool {
        if let catalogEnabled { return catalogEnabled }
        guard let host = URL(string: serverURL.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host != "ntfy.sh"
    }

    /// Enabled topics plus the account sync topic, which is streamed but never listed.
    var streamTopicNames: [String] {
        var names = enabledTopicNames
        if isCatalogEnabled, let sync = syncTopic, !sync.isEmpty, !names.contains(sync) { names.append(sync) }
        return names
    }

    /// Groups `names` by catalog app, keeping first-appearance order of groups and of topics.
    func groupedByApp(_ names: [String]) -> [TopicGroup] {
        var groups: [TopicGroup] = []
        for name in names {
            let config = topic(name)
            let label = config?.appName
            if let i = groups.firstIndex(where: { $0.label == label }) {
                groups[i].topics.append(name)
            } else {
                groups.append(TopicGroup(label: label, icon: config?.appIcon, topics: [name]))
            }
        }
        return groups
    }
}
