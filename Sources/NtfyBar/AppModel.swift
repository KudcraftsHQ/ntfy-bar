import AppKit
import Network
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private static let maxEntries = 2000
    private static let maxSeenIds = 2000
    /// Messages older than (launch - grace) are backlog: listed, but never notified.
    private static let notifyGrace: TimeInterval = 60

    // MARK: Observable state

    private(set) var entries: [Entry] = []
    var status: ConnectionStatus = .notConfigured
    private(set) var hasPassword = false
    private(set) var hasToken = false
    var notificationsAllowed: Bool?
    // Catalog sync state (AppModel+Catalog.swift).
    var lastCatalogSync: Date?
    var catalogError: String?
    @ObservationIgnored var catalogTask: Task<Void, Never>?
    @ObservationIgnored var catalogETag: String?
    /// Credentials were rejected (401): stays set until a sign-in or a successful request.
    var needsSignIn = false
    @ObservationIgnored var suppressRestarts = false

    var settings: AppSettings {
        didSet {
            guard settings != oldValue, persistenceEnabled else { return }
            Storage.saveSettings(settings)
            guard !suppressRestarts else { return }
            let connectionChanged = settings.serverURL != oldValue.serverURL
                || settings.username != oldValue.username
                || settings.streamTopicNames != oldValue.streamTopicNames
            if connectionChanged { scheduleReconnect() }
            if settings.serverURL != oldValue.serverURL || settings.catalogEnabled != oldValue.catalogEnabled {
                restartCatalogSync(resetETag: true)
            }
        }
    }

    var unreadCount: Int {
        entries.reduce(0) { count, entry in
            let topic = entry.message.topic
            return count + (!entry.read && !settings.isMuted(topic) && settings.isEnabled(topic) ? 1 : 0)
        }
    }

    // MARK: Internals

    @ObservationIgnored private var password: String
    @ObservationIgnored private var token: String
    @ObservationIgnored private var lastMessageId: String?
    @ObservationIgnored private var lastMessageTime: Int?
    @ObservationIgnored private var seenOrder: [String] = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var started = false
    /// Off in snapshot mode so rendering sample data never touches state.json.
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private let launchTime = Date()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120      // idle timeout; ntfy keepalive is ~45s
        config.timeoutIntervalForResource = 60 * 60 * 24 * 365
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {
        var initial: AppSettings
        if let saved = Storage.loadSettings() {
            initial = saved
        } else {
            initial = AppSettings()
            Self.importCLIConfig(into: &initial)
            Storage.saveSettings(initial)
        }
        let pw = Keychain.get("password") ?? ""
        let tk = Keychain.get("token") ?? ""
        password = pw
        token = tk
        settings = initial
        hasPassword = !pw.isEmpty
        hasToken = !tk.isEmpty
    }

    private static func importCLIConfig(into settings: inout AppSettings) {
        guard let cli = CLIConfigImporter.load() else {
            Log.write("import: no ntfy CLI config found")
            return
        }
        settings.serverURL = cli.host ?? ""
        settings.username = cli.user ?? ""
        settings.topics = cli.topics.map { TopicConfig(name: $0) }
        if let pw = cli.password, !pw.isEmpty { Keychain.set(pw, for: "password") }
        if let tk = cli.token, !tk.isEmpty { Keychain.set(tk, for: "token") }
        Log.write("import: imported host, user and \(cli.topics.count) topics from ntfy CLI config")
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Log.rotateIfNeeded()
        Log.write("launch")

        let state = Storage.load()
        entries = state.entries
        lastMessageId = state.lastMessageId
        lastMessageTime = state.lastMessageTime
        seenOrder = state.seenIds
        seen = Set(seenOrder).union(entries.map(\.id))

        Notifier.requestAuthorization { granted in
            Task { @MainActor in AppModel.shared.notificationsAllowed = granted }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Log.write("wake: reconnecting")
                AppModel.shared.restartStream()
                AppModel.shared.restartCatalogSync()
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let signature = "\(satisfied)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in AppModel.shared.handlePathChange(satisfied: satisfied, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "com.kudcrafts.ntfy-bar.path"))
        pathMonitor = monitor

        restartStream()
        restartCatalogSync()
        if !settings.isConfigured && !(settings.isCatalogEnabled && authorizationHeader != nil) { SettingsWindowController.shared.show() }
    }

    private func handlePathChange(satisfied: Bool, signature: String) {
        defer { lastPathSignature = signature }
        guard let previous = lastPathSignature, previous != signature else { return }
        Log.write("network: path changed (satisfied=\(satisfied))")
        if satisfied { restartStream() }
    }

    // MARK: Credentials

    func updateCredentials(password newPassword: String?, token newToken: String?) {
        if let newPassword {
            password = newPassword
            Keychain.set(newPassword, for: "password")
            hasPassword = !newPassword.isEmpty
        }
        if let newToken {
            token = newToken
            Keychain.set(newToken, for: "token")
            hasToken = !newToken.isEmpty
        }
        needsSignIn = false
        if settings.syncTopic != nil { settings.syncTopic = nil }  // belongs to the previous account
        restartStream()
        restartCatalogSync(resetETag: true)
    }

    var authorizationHeader: String? {
        if !token.isEmpty { return "Bearer \(token)" }
        guard !settings.username.isEmpty else { return nil }
        let raw = "\(settings.username):\(password)"
        return "Basic \(Data(raw.utf8).base64EncodedString())"
    }

    /// Credentials are only sent to the ntfy server itself, never to third-party icon hosts.
    func authorization(for url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == URL(string: settings.serverURL)?.host?.lowercased() else { return nil }
        return authorizationHeader
    }

    // MARK: Streaming

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            restartStream()
        }
    }

    func restartStream() {
        streamTask?.cancel()
        attempt = 0
        streamTask = Task { await runLoop() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard settings.isConfigured, let url = streamURL() else {
                status = .notConfigured
                return
            }
            status = attempt == 0 ? .connecting : status
            do {
                try await streamOnce(url: url)
                Log.write("stream: closed by server")
                attempt += 1
                status = .reconnecting(reason: "Connection closed", retryAt: Date().addingTimeInterval(backoff()))
            } catch is CancellationError {
                return
            } catch StreamError.unauthorized(let code) {
                attempt += 1
                status = .authError(retryAt: Date().addingTimeInterval(backoff()))
                Log.write("stream: auth error HTTP \(code)")
                handleStreamAuthFailure(code)
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                let reason = (error as? StreamError)?.description ?? error.localizedDescription
                status = .reconnecting(reason: reason, retryAt: Date().addingTimeInterval(backoff()))
                Log.write("stream: error: \(reason)")
            }
            let delay: TimeInterval
            switch status {
            case .reconnecting(_, let at), .authError(let at): delay = max(1, at.timeIntervalSinceNow)
            default: delay = 1
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Exponential backoff with jitter: 1, 2, 4 … capped at 60s.
    private func backoff() -> TimeInterval {
        let base = min(60, pow(2, Double(max(0, attempt - 1))))
        return base * Double.random(in: 0.85...1.15)
    }

    private func streamURL() -> URL? {
        var base = settings.serverURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        let topics = settings.streamTopicNames.joined(separator: ",")
        guard var comps = URLComponents(string: "\(base)/\(topics)/json") else { return nil }
        if let since = sinceParameter() { comps.queryItems = [URLQueryItem(name: "since", value: since)] }
        return comps.url
    }

    /// Resume from the last seen message. Message IDs only resolve while the server still
    /// caches them (12h by default), so fall back to a timestamp for older positions.
    /// First-ever connect pulls 1h of backlog into the list without notifying.
    private func sinceParameter() -> String? {
        guard let time = lastMessageTime else { return "1h" }
        if let id = lastMessageId, Date().timeIntervalSince1970 - TimeInterval(time) < 6 * 3600 { return id }
        return String(time)
    }

    enum StreamError: Error, CustomStringConvertible {
        case unauthorized(Int)
        case http(Int)
        var description: String {
            switch self {
            case .unauthorized(let c): "HTTP \(c)"
            case .http(let c): "Server returned HTTP \(c)"
            }
        }
    }

    private func streamOnce(url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        if let auth = authorizationHeader { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        Log.write("stream: connecting (topics=\(settings.enabledTopicNames.count), since=\(url.query ?? "none"))")

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw StreamError.unauthorized(http.statusCode) }
            if !(200..<300).contains(http.statusCode) { throw StreamError.http(http.statusCode) }
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(NtfyEvent.self, from: data) else { continue }
            switch event.event {
            case "open":
                attempt = 0
                status = .connected
                needsSignIn = false
                Log.write("stream: open")
                restartCatalogSync()
            case "keepalive":
                if status != .connected { status = .connected }
            case "message":
                if let message = event.asMessage { ingest(message) }
            default:
                break
            }
        }
    }

    // MARK: Messages

    /// `notify: false` is catalog backfill: listed, never notified, and the stream cursor stays put.
    func ingest(_ m: NtfyMessage, notify: Bool = true) {
        if m.topic == settings.syncTopic {
            if CatalogSync.isSyncSignal(m.message) { restartCatalogSync() }
            return
        }
        if notify && m.time >= (lastMessageTime ?? 0) {
            lastMessageTime = m.time
            lastMessageId = m.id
        }
        guard !seen.contains(m.id) else { return }
        markSeen(m.id)

        let index = entries.firstIndex { $0.message.time <= m.time } ?? entries.endIndex
        entries.insert(Entry(message: m, read: false), at: index)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }

        let fresh = m.date >= launchTime.addingTimeInterval(-Self.notifyGrace)
        let muted = settings.isMuted(m.topic)
        let notifies = notify && fresh && !muted
        if notifies {
            let sound = settings.soundForAll
            let soundClass = settings.topic(m.topic)?.sound
            let auth = m.thumbnailURL.flatMap(authorization(for:))
            Task { await Notifier.post(m, soundForAll: sound, soundClass: soundClass, authorization: auth) }
        }
        Log.write("message: id=\(m.id) topic=\(m.topic) notified=\(notifies)")
        scheduleSave()
    }

    private func markSeen(_ id: String) {
        seen.insert(id)
        seenOrder.append(id)
        if seenOrder.count > Self.maxSeenIds {
            let drop = seenOrder.count - Self.maxSeenIds
            for old in seenOrder.prefix(drop) { seen.remove(old) }
            seenOrder.removeFirst(drop)
            seen.formUnion(entries.map(\.id))
        }
    }

    func markRead(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for i in entries.indices where !entries[i].read && ids.contains(entries[i].id) {
            entries[i].read = true
            changed = true
        }
        if changed { scheduleSave() }
    }

    func markAllRead() {
        markRead(Set(entries.map(\.id)))
        UNUserNotificationCenterBridge.removeAllDelivered()
    }

    func clear(topic: String? = nil) {
        if let topic { entries.removeAll { $0.message.topic == topic } } else { entries.removeAll() }
        scheduleSave()
    }

    func open(_ entry: Entry) {
        markRead([entry.id])
        if let url = entry.message.openURL { NSWorkspace.shared.open(url) }
    }

    func handleNotificationClick(id: String?, url: URL?) {
        if let id { markRead([id]) }
        if let url { NSWorkspace.shared.open(url) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        guard persistenceEnabled else { return }
        Storage.save(PersistedState(entries: entries, lastMessageId: lastMessageId,
                                    lastMessageTime: lastMessageTime, seenIds: seenOrder))
    }

    /// Snapshot mode: show the given entries, never connect or persist.
    func prepareSnapshot(entries: [Entry], status: ConnectionStatus, settings: AppSettings? = nil) {
        persistenceEnabled = false
        started = true
        if let settings { self.settings = settings }
        self.entries = entries
        self.status = status
        notificationsAllowed = true
    }

    // MARK: Launch at login

    var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

import UserNotifications

enum UNUserNotificationCenterBridge {
    static func removeAllDelivered() { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
}
