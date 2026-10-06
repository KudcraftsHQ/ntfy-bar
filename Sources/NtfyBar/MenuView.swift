import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: String?
    /// Messages that were unread when the popover opened. They are marked read right away,
    /// but keep their dot for this viewing so it's clear what's new.
    @State private var fresh: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 0
    @State private var lastOpened = Date.distantPast
    @State private var windowRef = WindowRef()

    static let width: CGFloat = 380

    private var visible: [Entry] {
        guard let filter else { return model.entries }
        return model.entries.filter { $0.message.topic == filter }
    }

    private func isNew(_ entry: Entry) -> Bool { fresh.contains(entry.id) || !entry.read }

    /// Enabled topics that have messages, in configured order, then leftovers.
    private var chipTopics: [String] {
        let present = Set(model.entries.map(\.message.topic)).filter(model.settings.isEnabled)
        var ordered = model.settings.topicNames.filter(present.contains)
        ordered += present.subtracting(ordered).sorted()
        return ordered
    }

    /// Newest icon seen per topic, so rows without their own icon still match their siblings.
    private var topicIcons: [String: URL] {
        var icons: [String: URL] = [:]
        for entry in model.entries {
            if icons[entry.message.topic] == nil, let url = entry.message.iconURL {
                icons[entry.message.topic] = url
            }
        }
        return icons
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if chipTopics.count > 1 { chips }
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: Self.width)
        .background(WindowReader(ref: windowRef))
        .onAppear(perform: popoverOpened)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let w = note.object as? NSWindow, w === windowRef.window { popoverOpened() }
        }
        .onChange(of: filter) { markVisibleRead(reset: false) }
    }

    private func popoverOpened() {
        let reset = Date().timeIntervalSince(lastOpened) > 1
        lastOpened = Date()
        if let filter, !chipTopics.contains(filter) { self.filter = nil }
        if reset { expanded.removeAll() }
        markVisibleRead(reset: reset)
    }

    private func markVisibleRead(reset: Bool) {
        let unread = Set(visible.lazy.filter { !$0.read }.map(\.id))
        fresh = reset ? unread : fresh.union(unread)
        model.markRead(unread)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("ntfy")
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(model.status.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .help(model.status.detail ?? model.settings.serverURL)
            }
            Spacer()
            QuietIconButton(symbol: "envelope.open", help: "Mark all as read") {
                model.markAllRead()
                fresh.removeAll()
            }
            .disabled(fresh.isEmpty && model.unreadCount == 0)
            Menu {
                Button("Mark All as Read") { model.markAllRead(); fresh.removeAll() }
                Divider()
                if let filter {
                    Button("Clear \(filter)…") { confirmClear(topic: filter) }
                }
                Button("Clear All…") { confirmClear(topic: nil) }
                    .disabled(model.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .authError: .red
        case .notConfigured: .gray
        }
    }

    private func confirmClear(topic: String?) {
        let alert = NSAlert()
        alert.messageText = topic.map { "Clear messages from \($0)?" } ?? "Clear all messages?"
        alert.informativeText = "They are removed from this list. New messages keep arriving."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.clear(topic: topic)
            fresh.removeAll()
        }
    }

    // MARK: Topic filter

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Segment(title: "All", count: model.entries.filter(isNew).count, selected: filter == nil) {
                    filter = nil
                }
                ForEach(chipTopics, id: \.self) { topic in
                    Segment(title: topic,
                            count: model.entries.filter { $0.message.topic == topic && isNew($0) }.count,
                            selected: filter == topic,
                            muted: model.settings.isMuted(topic)) {
                        filter = filter == topic ? nil : topic
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 10)
    }

    // MARK: List

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [Entry]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for entry in visible {
            let day = calendar.startOfDay(for: entry.message.date)
            if let last = result.last, last.day == day {
                result[result.count - 1] = DayGroup(day: day, entries: last.entries + [entry])
            } else {
                result.append(DayGroup(day: day, entries: [entry]))
            }
        }
        return result
    }

    @ViewBuilder
    private var content: some View {
        if visible.isEmpty {
            emptyState
        } else {
            let groups = self.groups
            let showHeaders = groups.count > 1 || !Calendar.current.isDateInToday(groups[0].day)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            if showHeaders {
                                Text(dayTitle(group.day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, group.id == groups.first?.id ? 6 : 12)
                                    .padding(.bottom, 4)
                            }
                            ForEach(group.entries) { entry in
                                MessageRow(
                                    entry: entry,
                                    iconURL: entry.message.iconURL ?? topicIcons[entry.message.topic],
                                    isNew: isNew(entry),
                                    expanded: expanded.contains(entry.id),
                                    now: context.date,
                                    open: { model.open(entry) },
                                    toggleExpanded: {
                                        if expanded.contains(entry.id) { expanded.remove(entry.id) }
                                        else { expanded.insert(entry.id) }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: listHeight(groups: groups, headers: showHeaders))
        }
    }

    private func listHeight(groups: [DayGroup], headers: Bool) -> CGFloat {
        let maxHeight: CGFloat = 470
        if contentHeight > 0 { return min(maxHeight, contentHeight) }
        let rows = groups.reduce(0) { $0 + $1.entries.count }
        let estimate = CGFloat(rows) * 86 + (headers ? CGFloat(groups.count) * 30 : 0) + 12
        return min(maxHeight, estimate)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.settings.isConfigured ? "bell" : "bell.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            if model.settings.isConfigured {
                Text(filter == nil ? "No messages yet" : "No messages in \(filter!)")
                    .font(.system(size: 13, weight: .medium))
                Text("New messages from \(model.settings.enabledTopicNames.count) topics appear here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect to your ntfy server")
                    .font(.system(size: 13, weight: .medium))
                Button("Open Settings…") { SettingsWindowController.shared.show() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            FooterButton(title: "Settings…", symbol: "gearshape") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
            Spacer()
            FooterButton(title: "Quit", symbol: nil) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Components

private struct QuietIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.5))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct Segment: View {
    let title: String
    let count: Int
    let selected: Bool
    var muted = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if muted {
                    Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 15)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MessageRow: View {
    let entry: Entry
    let iconURL: URL?
    let isNew: Bool
    let expanded: Bool
    let now: Date
    let open: () -> Void
    let toggleExpanded: () -> Void
    @State private var hovering = false

    private var m: NtfyMessage { entry.message }
    private var preview: String { TextUtil.preview(m.body) }
    private var expandable: Bool {
        let p = preview
        return p.count > 90 || p.filter { $0 == "\n" }.count >= 2
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MessageIcon(url: iconURL, topic: m.topic)
                .overlay(alignment: .bottomTrailing) {
                    if m.effectivePriority >= 4 { PriorityBadge(priority: m.effectivePriority).offset(x: 4, y: 4) }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(m.date.formatted(date: .abbreviated, time: .standard))
                }
                if m.hasTitle {
                    Text(m.topic)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !preview.isEmpty {
                    HStack(alignment: .bottom, spacing: 4) {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if expandable && (hovering || expanded) {
                            Button(action: toggleExpanded) {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help(expanded ? "Show less" : "Show more")
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .offset(x: 7, y: 9 + 16 - 3.5)
                .opacity(isNew ? 1 : 0)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(m.openURL?.absoluteString ?? "")
    }

    private var timeLabel: String {
        let seconds = now.timeIntervalSince(m.date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return m.date.formatted(date: .omitted, time: .shortened)
    }
}

private struct PriorityBadge: View {
    let priority: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: priority >= 5 ? "exclamationmark.2" : "exclamationmark")
            .font(.system(size: 7.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(priority >= 5 ? Color.red : Color.orange))
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5).padding(-1.5))
            .help(priority >= 5 ? "Urgent priority" : "High priority")
    }
}

/// Message icon (32pt continuous rounded rect) with a deterministic per-topic fallback.
struct MessageIcon: View {
    let url: URL?
    let topic: String
    @State private var loaded: NSImage?

    static let size: CGFloat = 32

    private var image: NSImage? { loaded ?? url.flatMap { IconImageStore.shared.cached($0) } }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                fallback
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: url) {
            guard let url else { loaded = nil; return }
            loaded = await IconImageStore.shared.load(url, authorization: AppModel.shared.authorization(for: url))
        }
    }

    private var fallback: some View {
        ZStack {
            Rectangle().fill(Self.color(for: topic).gradient)
            Text(String(topic.first(where: \.isLetter) ?? "#").uppercased())
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    /// Stable across launches (String.hashValue is randomly seeded).
    static func color(for topic: String) -> Color {
        var hash: UInt32 = 5381
        for byte in topic.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.75)
    }
}

/// Holds a weak reference to the popover's NSWindow (not observed by SwiftUI).
final class WindowRef {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.ref = ref
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.ref = ref
    }

    final class ReportingView: NSView {
        var ref: WindowRef?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref?.window = window
        }
    }
}
