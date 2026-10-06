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
    static func post(_ m: NtfyMessage, soundForAll: Bool, authorization: String?) async {
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
        if soundForAll || m.effectivePriority >= 4 { content.sound = .default }
        if m.effectivePriority <= 2 { content.interruptionLevel = .passive }
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
