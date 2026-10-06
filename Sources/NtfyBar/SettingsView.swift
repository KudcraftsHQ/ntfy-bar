import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // Connection drafts — applied together with "Save & Reconnect".
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var loaded = false

    @State private var newTopic = ""
    @State private var topicError: String?
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var pendingRemoval: String?
    @State private var signingIn = false
    @State private var signInError: String?

    private var connectionDirty: Bool {
        server != model.settings.serverURL || username != model.settings.username
            || !password.isEmpty || !token.isEmpty
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Server URL", text: $server, prompt: Text("https://ntfy.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password,
                            prompt: Text(model.hasPassword ? "Saved in Keychain" : "Not set"))
                SecureField("Access token", text: $token,
                            prompt: Text(model.hasToken ? "Saved in Keychain" : "Optional — overrides password"))
                HStack {
                    statusLine
                    Spacer()
                    if model.hasToken {
                        Button("Remove Token") { model.updateCredentials(password: nil, token: "") }
                    }
                    Button("Save & Reconnect", action: applyConnection)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!connectionDirty)
                }
                HStack {
                    if let signInError {
                        Text(signInError).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button(signingIn ? "Signing In…" : "Sign In", action: signIn)
                        .disabled(signingIn || CatalogSync.normalizedBase(server) == nil
                                  || username.isEmpty || password.isEmpty)
                        .help("Swaps the password for a token for this Mac, then forgets the password")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Password and token are stored in the Keychain. Leave a field empty to keep the saved value. Sign In creates an access token for this Mac and keeps only the token.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sync topics from the server", isOn: Binding(
                    get: { model.settings.isCatalogEnabled },
                    set: { model.settings.catalogEnabled = $0 }
                ))
                if model.settings.isCatalogEnabled {
                    HStack {
                        Text(model.lastCatalogSync.map { "Last synced \($0.formatted(date: .omitted, time: .shortened))" }
                             ?? "Not synced yet")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync Now") { model.restartCatalogSync(resetETag: true) }
                            .disabled(!model.hasToken && !model.hasPassword)
                    }
                    if let error = model.catalogError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Catalog")
            } footer: {
                Text("Every topic you can read on the server is added automatically, grouped by app. Synced topics can be turned off or muted, not removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.settings.topics.isEmpty {
                    Text("No topics yet").foregroundStyle(.secondary)
                }
                ForEach($model.settings.topics) { $topic in
                    TopicRow(topic: $topic) { pendingRemoval = topic.name }
                }
                HStack {
                    TextField("Add topic", text: $newTopic)
                        .onSubmit(addTopic)
                    Button("Add", action: addTopic)
                        .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let topicError {
                    Text(topicError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Topics")
            } footer: {
                Text("Turn a topic off to stop subscribing without losing it. Muted topics are still listed but never notify. Right-click a topic to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Play sound for every message", isOn: $model.settings.soundForAll)
                Text("High-priority messages (4–5) always play a sound. Muted topics never notify.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.notificationsAllowed == false {
                    HStack {
                        Text("Notifications are not allowed for ntfy-bar.")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    Text("Approve ntfy-bar in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .confirmationDialog(
            "Remove topic \(pendingRemoval ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { name in
            Button("Remove", role: .destructive) {
                model.settings.topics.removeAll { $0.name == name }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its history will be kept. To stop receiving it temporarily, turn it off instead.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            server = model.settings.serverURL
            username = model.settings.username
        }
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(model.status.label).font(.caption).foregroundStyle(.secondary)
        }
        .help(model.status.detail ?? "")
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .authError: .red
        case .notConfigured: .gray
        }
    }

    private func applyConnection() {
        var s = model.settings
        s.serverURL = server.trimmingCharacters(in: .whitespacesAndNewlines)
        s.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings = s
        model.updateCredentials(password: password.isEmpty ? nil : password,
                                token: token.isEmpty ? nil : token)
        server = s.serverURL
        username = s.username
        password = ""
        token = ""
    }

    private func signIn() {
        signingIn = true
        signInError = nil
        Task {
            do {
                try await model.signIn(server: server, username: username, password: password)
                server = model.settings.serverURL
                username = model.settings.username
                password = ""
                token = ""
            } catch {
                signInError = (error as? CatalogSync.FetchError).map { "Sign in failed: \($0.description)" }
                    ?? "Sign in failed: \(error.localizedDescription)"
            }
            signingIn = false
        }
    }

    private func addTopic() {
        let name = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard name.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression) != nil else {
            topicError = "Topics may only contain letters, digits, - and _ (max 64)."
            return
        }
        guard !model.settings.topicNames.contains(name) else {
            topicError = "Already subscribed to \(name)."
            return
        }
        model.settings.topics.append(TopicConfig(name: name))
        newTopic = ""
        topicError = nil
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try model.setLaunchAtLogin(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// One topic in Settings: enable switch, mute toggle, and a removal path that takes intent
/// (hover-revealed menu or right-click, both followed by a confirmation dialog).
private struct TopicRow: View {
    @Binding var topic: TopicConfig
    let requestRemoval: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: $topic.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(topic.enabled ? "Subscribed — turn off to pause this topic" : "Off — not subscribed")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(topic.displayName ?? topic.name)
                        .foregroundStyle(topic.enabled ? .primary : .tertiary)
                    if isManaged { ManagedBadge() }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isManaged {
                Menu {
                    Button("Remove \(topic.name)…", role: .destructive, action: requestRemoval)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .help("More")
            }
            Toggle(isOn: $topic.muted) {
                Image(systemName: topic.muted ? "bell.slash" : "bell")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .disabled(!topic.enabled)
            .help(topic.muted ? "Muted — listed, but no notifications" : "Mute notifications")
        }
        .opacity(topic.enabled ? 1 : 0.6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(topic.enabled ? "Turn Off" : "Turn On") { topic.enabled.toggle() }
            Button(topic.muted ? "Unmute" : "Mute") { topic.muted.toggle() }
            if !isManaged {
                Divider()
                Button("Remove \(topic.name)…", role: .destructive, action: requestRemoval)
            }
        }
    }

    /// Synced from the catalog: can be turned off or muted, never removed (it would come back).
    private var isManaged: Bool { topic.managed == true }

    /// "FaceMap · facemap-orders": the app, plus the topic id when a display name hides it.
    private var subtitle: String? {
        let parts = [topic.appName, topic.displayName == nil ? nil : topic.name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
