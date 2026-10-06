import AppKit
import Foundation

/// Catalog sync (spec §8): fetch `/v1/catalog` on launch, wake, credential/server changes, every
/// stream (re)connect, every sync-topic event and every 15 minutes; reconcile the topic list.
extension AppModel {
    static let catalogInterval: Duration = .seconds(15 * 60)

    /// Cancels any running sync and starts the loop again with an immediate fetch.
    /// `resetETag` forces a full 200 (credentials changed, or the server said the view changed).
    func restartCatalogSync(resetETag: Bool = false) {
        catalogTask?.cancel()
        catalogTask = nil
        if resetETag { catalogETag = nil }
        guard settings.isCatalogEnabled, authorizationHeader != nil,
              CatalogSync.normalizedBase(settings.serverURL) != nil else { return }
        catalogTask = Task {
            while !Task.isCancelled {
                await syncCatalogOnce()
                try? await Task.sleep(for: Self.catalogInterval)
            }
        }
    }

    private func syncCatalogOnce() async {
        guard let auth = authorizationHeader, let base = CatalogSync.normalizedBase(settings.serverURL) else { return }
        do {
            let (catalog, etag) = try await CatalogSync.fetch(base: base, auth: auth, etag: catalogETag,
                                                              session: CatalogSync.session)
            try Task.checkCancellation()
            lastCatalogSync = Date()
            catalogError = nil
            needsSignIn = false
            guard let catalog else { return }  // 304: nothing changed

            let known = Set(settings.topicNames)
            var next = settings
            next.topics = CatalogSync.reconcile(current: settings.topics, catalog: catalog)
            next.syncTopic = catalog.syncTopic
            let added = next.topics.filter { $0.enabled && !known.contains($0.name) }.map(\.name)
            Log.write("catalog: version=\(catalog.version) topics=\(next.topics.count) added=\(added.count)")

            // Backfill before the settings change triggers a reconnect, so the reconnected stream
            // finds these messages already seen and never notifies about history.
            if !added.isEmpty, let url = CatalogSync.backfillURL(base: base, topics: added) {
                do {
                    let messages = try await CatalogSync.poll(url: url, auth: auth, session: CatalogSync.session)
                    try Task.checkCancellation()
                    for m in messages.sorted(by: { $0.time < $1.time }) { ingest(m, notify: false) }
                    Log.write("catalog: backfilled \(messages.count) messages")
                } catch is CancellationError {
                    return
                } catch {
                    Log.write("catalog: backfill failed: \(error)")
                }
            }
            catalogETag = etag
            settings = next
        } catch is CancellationError {
            return
        } catch CatalogSync.FetchError.unauthorized(let code) {
            guard !Task.isCancelled else { return }
            Log.write("catalog: auth error HTTP \(code)")
            if code == 401 {
                catalogError = "Your sign-in is no longer valid. Sign in again."
                status = .authError(retryAt: Date().addingTimeInterval(15 * 60))
                markNeedsSignIn()
            } else {
                catalogError = "Not allowed to read the catalog (HTTP \(code))."
            }
        } catch {
            guard !Task.isCancelled else { return }
            if (error as? URLError)?.code == .cancelled { return }
            catalogError = (error as? CatalogSync.FetchError)?.description ?? error.localizedDescription
            Log.write("catalog: error: \(catalogError ?? "")")
        }
    }

    /// 401 = the token/password is no longer accepted (revoked, user deleted): ask to sign in again.
    /// 403 = some topic in the stream is no longer readable; a catalog sync drops it.
    func handleStreamAuthFailure(_ code: Int) {
        if code == 401 { markNeedsSignIn() } else { restartCatalogSync() }
    }

    /// Sticky until a sign-in or a successful request (a keepalive can't clear it), and opens
    /// Settings once when it first happens.
    func markNeedsSignIn() {
        guard !needsSignIn else { return }
        needsSignIn = true
        Log.write("auth: credentials rejected, asking to sign in again")
        SettingsWindowController.shared.show()
    }

    /// Exchanges username + password for a per-device token, then forgets the password.
    func signIn(server: String, username: String, password: String) async throws {
        guard let base = CatalogSync.normalizedBase(server) else { throw CatalogSync.FetchError.badResponse }
        let label = CatalogSync.tokenLabel(hostName: Host.current().localizedName)
        let token = try await CatalogSync.mintToken(base: base, username: username, password: password,
                                                    label: label, session: CatalogSync.session)
        var next = settings
        next.serverURL = server.trimmingCharacters(in: .whitespacesAndNewlines)
        next.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        next.syncTopic = nil  // the previous account's
        // Apply server + user without restarting anything, so no request ever pairs the old
        // credentials with the new server; updateCredentials then restarts stream and catalog once.
        suppressRestarts = true
        settings = next
        suppressRestarts = false
        updateCredentials(password: "", token: token)
        Log.write("catalog: signed in, token label=\(label)")
    }
}
