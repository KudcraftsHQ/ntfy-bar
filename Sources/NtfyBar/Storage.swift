import Foundation

struct PersistedState: Codable, Sendable {
    var entries: [Entry] = []
    var lastMessageId: String?
    var lastMessageTime: Int?
    var seenIds: [String] = []
}

enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ntfy-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var stateURL: URL { directory.appendingPathComponent("state.json") }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    static func save(_ state: PersistedState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.write("state: save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Settings (UserDefaults; secrets live in Keychain)

    private static let settingsKey = "settings.v1"

    static func loadSettings() -> AppSettings? {
        guard let data = UserDefaults.standard.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    static func saveSettings(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}

/// Imports server/user/password/topics from the ntfy CLI config on first run.
/// Hand-rolled line parser — handles the flat keys and `subscribe:` → `- topic: x` items.
enum CLIConfigImporter {
    struct Result {
        var host: String?
        var user: String?
        var password: String?
        var token: String?
        var topics: [String] = []
    }

    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ntfy/client.yml")
    }

    static func load(from url: URL = defaultPath) -> Result? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Result {
        var result = Result()
        var inSubscribe = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = line.first == " " || line.first == "\t" || trimmed.hasPrefix("-")
            if !indented {
                inSubscribe = trimmed.hasPrefix("subscribe:")
                guard let (key, value) = keyValue(trimmed) else { continue }
                switch key {
                case "default-host": result.host = value
                case "default-user": result.user = value
                case "default-password": result.password = value
                case "default-token": result.token = value
                default: break
                }
            } else if inSubscribe {
                var item = trimmed
                if item.hasPrefix("- ") { item.removeFirst(2) }
                if let (key, value) = keyValue(item), key == "topic", !value.isEmpty {
                    // Topics may be full URLs (https://host/topic); keep the last path component.
                    let name = value.split(separator: "/").last.map(String.init) ?? value
                    if !result.topics.contains(name) { result.topics.append(name) }
                }
            }
        }
        return result
    }

    private static func stripComment(_ line: String) -> String {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return "" }
        if let r = line.range(of: " #") { return String(line[..<r.lowerBound]) }
        return line
    }

    private static func keyValue(_ s: String) -> (String, String)? {
        guard let idx = s.firstIndex(of: ":") else { return nil }
        let key = s[..<idx].trimmingCharacters(in: .whitespaces)
        var value = s[s.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let f = value.first, let l = value.last, f == l, f == "\"" || f == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }
}
