import AppKit
import SwiftUI
import UserNotifications

struct NtfyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let unread = model.unreadCount
        HStack(spacing: 2) {
            Image(nsImage: MascotGlyph.image(glyph(unread: unread)))
            if unread > 0 && model.settings.showsUnreadCount { Text(unread > 99 ? "99+" : "\(unread)") }
        }
    }

    private func glyph(unread: Int) -> MascotGlyph.State {
        switch model.status {
        case .authError, .notConfigured: .asleep
        default: unread > 0 ? .unread : .idle
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        AppModel.shared.start()
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.saveNow()
    }
}

/// Settings live in a plain AppKit window: reliable to bring forward from an accessory app.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            // Fresh hosting controller each time so drafts reload from current settings.
            window.contentViewController = NSHostingController(
                rootView: SettingsView().environment(AppModel.shared)
            )
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "ntfy-bar Settings"
        window.isReleasedWhenClosed = false
        return window
    }
}
