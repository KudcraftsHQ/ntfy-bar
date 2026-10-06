import AppKit
import SwiftUI

/// Small capsule marking a topic that the server catalog manages.
struct ManagedBadge: View {
    var body: some View {
        Text("synced")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("Added by the server catalog")
    }
}

/// Section label in the chip bar: the app's icon (via IconCache) and name.
struct AppGroupLabel: View {
    let name: String
    let icon: URL?
    @State private var loaded: NSImage?

    private var image: NSImage? { loaded ?? icon.flatMap { IconImageStore.shared.cached($0) } }

    var body: some View {
        HStack(spacing: 4) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .task(id: icon) {
            guard let icon else { loaded = nil; return }
            loaded = await IconImageStore.shared.load(icon, authorization: AppModel.shared.authorization(for: icon))
        }
    }
}

/// Shown in the popover while the server rejects our credentials (revoked token, deleted user).
struct SignInBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Signed out. Sign in again to keep receiving messages.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Sign In…") { SettingsWindowController.shared.show() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}
