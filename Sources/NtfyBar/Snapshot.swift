import AppKit
import SwiftUI

/// Renders the popover with persisted (or supplied) messages into a PNG, then exits.
@MainActor
enum Snapshot {
    static func run(args: [String]) {
        guard let out = args.first, !out.hasPrefix("--") else {
            FileHandle.standardError.write(Data("usage: ntfy-bar --snapshot out.png [--dark] [--sample] [--state f.json] [--empty]\n".utf8))
            exit(2)
        }
        let dark = args.contains("--dark")
        let empty = args.contains("--empty")
        var entries = Storage.load().entries
        if let i = args.firstIndex(of: "--state"), i + 1 < args.count,
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            entries = state.entries
        }
        var settings: AppSettings?
        if args.contains("--sample") {
            entries = SampleData.entries()
            settings = SampleData.settings
            SampleData.registerIcons()
        }
        if empty { entries = [] }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel.shared
        model.prepareSnapshot(entries: entries, status: .connected, settings: settings)

        Task { @MainActor in
            for url in Set(entries.compactMap(\.message.iconURL)) where IconImageStore.shared.cached(url) == nil {
                _ = await IconImageStore.shared.load(url, authorization: model.authorization(for: url))
            }
            await render(model: model, to: URL(fileURLWithPath: out), dark: dark)
            exit(0)
        }
        app.run()
    }

    private static func render(model: AppModel, to url: URL, dark: Bool) async {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = MenuView()
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("wrote \(url.path) (\(Int(size.width))×\(Int(size.height)) pt)")
        }
    }
}

/// Invented messages for README screenshots (no real servers, topics or data).
@MainActor
enum SampleData {
    static let settings = AppSettings(
        serverURL: "https://ntfy.example.com",
        username: "demo",
        topics: ["deploys", "alerts", "orders", "backups"].map { TopicConfig(name: $0) }
    )

    private static func icon(_ name: String) -> String { "https://ntfy.example.com/icons/\(name).png" }

    static func entries() -> [Entry] {
        let now = Date()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        func ago(_ minutes: Double) -> Int { Int(now.addingTimeInterval(-minutes * 60).timeIntervalSince1970) }
        func yday(_ h: Int, _ m: Int) -> Int {
            Int(cal.date(bySettingHour: h, minute: m, second: 0, of: yesterday)!.timeIntervalSince1970)
        }
        var n = 0
        func msg(_ topic: String, _ time: Int, _ title: String?, _ body: String, prio: Int? = nil,
                 icon: String? = nil, click: String? = nil, read: Bool = true) -> Entry {
            n += 1
            return Entry(message: NtfyMessage(id: "sample\(n)", time: time, topic: topic, title: title, message: body,
                                              priority: prio, click: click, icon: icon), read: read)
        }
        return [
            msg("deploys", ago(2), "Deploy succeeded",
                "**api** `v2.14.0` is live on production — built and rolled out in 2m 41s.",
                icon: icon("deploy"), click: "https://ci.example.com/runs/8812", read: false),
            msg("alerts", ago(14), "TypeError in checkout",
                "**TypeError: Cannot read properties of undefined (reading 'total')**\nProject: storefront\nEnvironment: production\n[View issue](https://errors.example.com/issues/1042)",
                prio: 4, icon: icon("alert"), click: "https://errors.example.com/issues/1042", read: false),
            msg("orders", ago(38), "New order #1048",
                "**$248.00** · 3 items\nShipping to Portland, OR — standard delivery",
                icon: icon("order")),
            msg("alerts", ago(95), "Disk usage at 94% on db-1",
                "Volume `/var/lib/postgresql` is almost full. Free space or grow the volume soon.",
                prio: 5, icon: icon("alert")),
            msg("backups", yday(3, 0), "Nightly backup completed",
                "Snapshot `pg-nightly` · 12.4 GB · checksum verified"),
            msg("deploys", yday(17, 22), "Deploy failed",
                "**web** build failed at step `bun run build` — 2 type errors in `checkout/summary.tsx`.",
                prio: 4, icon: icon("deploy")),
            msg("orders", yday(11, 5), "New order #1047",
                "**$64.50** · 1 item\nLocal pickup", icon: icon("order")),
        ]
    }

    /// Generic SF Symbol icons standing in for real ones.
    static func registerIcons() {
        let specs: [(String, String, NSColor, NSColor)] = [
            ("deploy", "shippingbox.fill", NSColor(srgbRed: 0.30, green: 0.36, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.45, green: 0.30, blue: 0.90, alpha: 1)),
            ("alert", "ladybug.fill", NSColor(srgbRed: 0.95, green: 0.35, blue: 0.30, alpha: 1), NSColor(srgbRed: 0.85, green: 0.20, blue: 0.40, alpha: 1)),
            ("order", "bag.fill", NSColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.95, green: 0.45, blue: 0.15, alpha: 1)),
        ]
        for (name, symbol, top, bottom) in specs {
            let size = NSSize(width: 128, height: 128)
            let image = NSImage(size: size, flipped: false) { rect in
                NSGradient(colors: [top, bottom])?.draw(in: rect, angle: -90)
                let config = NSImage.SymbolConfiguration(pointSize: 60, weight: .semibold)
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let g = glyph.size
                    let tinted = NSImage(size: g, flipped: false) { r in
                        glyph.draw(in: r)
                        NSColor.white.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2,
                                           width: g.width, height: g.height))
                }
                return true
            }
            if let url = URL(string: icon(name)) { IconImageStore.shared.insert(image, for: url) }
        }
    }
}
