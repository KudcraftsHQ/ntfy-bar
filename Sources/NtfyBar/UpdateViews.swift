import SwiftUI

/// Popover strip once an update is downloaded: it would install on quit, but a menu bar app is
/// rarely quit, so offer the restart here.
struct UpdateBanner: View {
    private let updater = Updater.shared

    var body: some View {
        if case .ready(let version) = updater.phase {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("ntfy-bar \(version) is ready to install.")
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Restart to Update") { updater.installNow() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
        }
    }
}

/// The popover's "More" menu entry: check, or install what was found.
struct UpdateMenuItem: View {
    private let updater = Updater.shared

    var body: some View {
        switch updater.phase {
        case .ready(let version):
            Button("Restart to Update to \(version)") { updater.installNow() }
        case .available(let version):
            Button("Update to \(version) Available…") { updater.checkForUpdates() }
        case .idle:
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable)
        }
    }
}

/// Settings › General: the running version, what's waiting, and the matching action.
struct UpdateSettingsRow: View {
    private let updater = Updater.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(Updater.version)").foregroundStyle(.secondary)
                switch updater.phase {
                case .ready(let version):
                    Text("\(version) downloaded. Installs when ntfy-bar quits.")
                        .font(.caption).foregroundStyle(.secondary)
                case .available(let version):
                    Text("\(version) available.")
                        .font(.caption).foregroundStyle(.secondary)
                case .idle:
                    if updater.isAvailable {
                        Text("Updates download and install automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            switch updater.phase {
            case .ready:
                Button("Restart to Update") { updater.installNow() }
            case .available:
                Button("Install Update…") { updater.checkForUpdates() }
            case .idle:
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
            }
        }
    }
}
