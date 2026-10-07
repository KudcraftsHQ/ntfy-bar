import AppKit
import Sparkle

/// Sparkle 2: EdDSA-signed updates from the GitHub Releases appcast (`SUFeedURL` in Info.plist).
/// Checks daily in the background and downloads silently (`SUAutomaticallyUpdate`). Once an update is
/// downloaded it installs on quit, or right away from "Restart to Update" in the popover or Settings.
@MainActor
@Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    enum Phase: Equatable {
        case idle
        /// Found in the appcast; downloading in the background, or waiting in Sparkle's own dialog.
        case available(version: String)
        /// Downloaded and staged; installs on quit, or now via `installNow()`.
        case ready(version: String)
    }

    static let shared = Updater()
    private(set) var phase: Phase = .idle
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var immediateInstall: (() -> Void)?

    private override init() {}

    /// Only inside a real .app that carries a feed: `swift run`, tests and snapshots never update.
    func start() {
        guard controller == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        Log.write("updater: started (version \(Self.version))")
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Installs the staged update and relaunches. Falls back to Sparkle's dialog if nothing is staged.
    func installNow() {
        guard let immediateInstall else { return checkForUpdates() }
        Log.write("updater: installing now")
        immediateInstall()
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if case .ready = phase { return }
        phase = .available(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Log.write("updater: \(item.displayVersionString) staged, installs on quit")
        immediateInstall = immediateInstallHandler
        phase = .ready(version: item.displayVersionString)
        return true  // we offer "Restart to Update"; Sparkle still installs on quit regardless
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if case .available = phase { phase = .idle }
    }
}
