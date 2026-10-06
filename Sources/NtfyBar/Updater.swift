import AppKit
import Sparkle

/// Sparkle 2: EdDSA-signed updates from the GitHub Releases appcast (`SUFeedURL` in Info.plist).
/// Checks daily in the background and installs silently on quit (`SUAutomaticallyUpdate`).
@MainActor
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    private init() {}

    /// Only inside a real .app that carries a feed: `swift run`, tests and snapshots never update.
    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        Log.write("updater: started (version \(Self.version))")
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
