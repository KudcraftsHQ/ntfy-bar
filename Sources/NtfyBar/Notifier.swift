import AppKit
import UserNotifications

enum Notifier {
    static func requestAuthorization(_ done: @escaping @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { Log.write("notifications: authorization error: \(error.localizedDescription)") }
            done(granted)
        }
    }

    /// Posts a notification. If the message has an image attachment or icon, it is fetched
    /// (disk-cached, ≤5s) and attached as the thumbnail; failures fall back to no image.
    /// `soundClass` is the catalog sound class of the topic (nil = not a catalog topic); its clip
    /// comes from `theme`.
    static func post(_ m: NtfyMessage, soundForAll: Bool, soundClass: String? = nil,
                     theme: SoundTheme = .fallback, authorization: String?) async {
        var attachment: UNNotificationAttachment?
        if let imageURL = m.thumbnailURL,
           let file = await IconCache.file(for: imageURL, authorization: authorization),
           let copy = IconCache.temporaryCopy(of: file) {
            let kind = m.attachment?.isImage == true ? "image attachment" : "icon"
            do {
                attachment = try UNNotificationAttachment(identifier: "thumbnail", url: copy, options: nil)
                Log.write("notification: attachment created (\(kind), \(file.lastPathComponent)) id=\(m.id)")
            } catch {
                Log.write("notification: attachment failed (\(kind)): \(error.localizedDescription)")
            }
        }

        let content = UNMutableNotificationContent()
        content.title = m.displayTitle
        if m.hasTitle { content.subtitle = m.topic }
        content.body = TextUtil.plain(m.body)
        content.threadIdentifier = m.topic
        let choice = CatalogSync.soundChoice(soundClass: soundClass, theme: theme, soundForAll: soundForAll,
                                             priority: m.effectivePriority)
        switch choice.sound {
        case .off: break
        case .system: content.sound = .default
        case .named(let file): content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: file))
        }
        if m.effectivePriority <= 2 { content.interruptionLevel = .passive }
        if choice.timeSensitive { content.interruptionLevel = .timeSensitive }
        if let attachment { content.attachments = [attachment] }
        var info: [String: String] = ["id": m.id]
        if let url = m.openURL { info["url"] = url.absoluteString }
        content.userInfo = info

        let request = UNNotificationRequest(identifier: m.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.write("notifications: post failed: \(error.localizedDescription)")
        }
    }
}

/// Shows banners even while our (accessory) app is frontmost, and handles clicks.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            AppModel.shared.handleNotificationClick(id: id, url: url)
        }
        completionHandler()
    }
}

/// Plays a bundled clip directly, for the theme preview in Settings.
@MainActor
enum SoundPreview {
    private static var playing: NSSound?

    static func play(_ theme: SoundTheme, _ sound: SoundClass) {
        playing?.stop()
        playing = nil
        guard let name = theme.clipName(sound),
              let url = Bundle.main.url(forResource: name, withExtension: "caf"),
              let clip = NSSound(contentsOf: url, byReference: true) else {
            Log.write("sound preview: \(theme.rawValue)/\(sound.rawValue) is not in the bundle")
            return
        }
        playing = clip
        clip.play()
    }
}

/// Copies the bundled clips into `~/Library/Sounds`. Notification Center resolves
/// `UNNotificationSound(named:)` there reliably; it does not always find them in the app bundle
/// (it then plays a built-in sound instead), and it remembers a miss until it restarts.
enum SoundInstaller {
    static var userSounds: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// Runs off the main thread; a failure only costs the themed sound.
    static func installBundledClips() {
        guard let resources = Bundle.main.resourceURL else { return }
        let destination = userSounds
        DispatchQueue.global(qos: .utility).async {
            do {
                let copied = try install(from: resources, to: destination)
                if copied > 0 { Log.write("sounds: installed \(copied) clips to ~/Library/Sounds") }
            } catch {
                Log.write("sounds: install failed: \(error.localizedDescription)")
            }
        }
    }

    /// Copies every `kc_*.caf` in `source` that `destination` lacks or holds a different version of.
    /// Returns how many were written.
    @discardableResult
    static func install(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let clips = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix("kc_") }
        var copied = 0
        for clip in clips {
            let target = destination.appendingPathComponent(clip.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                if fm.contentsEqual(atPath: clip.path, andPath: target.path) { continue }
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: clip, to: target)
            copied += 1
        }
        return copied
    }
}
