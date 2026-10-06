import Foundation
import XCTest
@testable import NtfyBar

final class CatalogSyncTests: XCTestCase {
    // MARK: Decoding

    /// The §3.1 example, verbatim minus the comments.
    static let catalogJSON = """
    {
      "version": 1759740000123,
      "base_url": "https://ntfy.kudcrafts.com",
      "history_days": 90,
      "sync_topic": "st_abc",
      "apps": [
        {
          "id": "facemap", "name": "FaceMap",
          "icon": "https://facemap.fyi/icon-192.png",
          "sound": "default",
          "topics": [
            { "topic": "facemap-orders", "name": "Orders", "sound": "alert",  "permission": "read-only" },
            { "topic": "facemap-alerts", "name": "",       "sound": "default", "permission": "read-write" }
          ]
        }
      ]
    }
    """

    func testDecodesSpecExample() throws {
        let c = try JSONDecoder().decode(Catalog.self, from: Data(Self.catalogJSON.utf8))
        XCTAssertEqual(c.version, 1_759_740_000_123)
        XCTAssertEqual(c.baseURL, "https://ntfy.kudcrafts.com")
        XCTAssertEqual(c.historyDays, 90)
        XCTAssertEqual(c.syncTopic, "st_abc")
        XCTAssertEqual(c.apps.count, 1)
        XCTAssertEqual(c.apps[0].icon, "https://facemap.fyi/icon-192.png")
        XCTAssertEqual(c.apps[0].topics.map(\.topic), ["facemap-orders", "facemap-alerts"])
        XCTAssertEqual(c.apps[0].topics[0].name, "Orders")
        XCTAssertNil(c.apps[0].topics[1].name, "empty name means: show the topic id")
        XCTAssertEqual(c.apps[0].topics[0].sound, "alert")
        XCTAssertEqual(c.apps[0].topics[0].permission, "read-only")
    }

    func testDecodesWithMissingOptionalFields() throws {
        let json = #"{"apps":[{"id":"kudtrading","name":"Kudtrading","icon":"","topics":[{"topic":"kudtrading"}]}]}"#
        let c = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.version, 0)
        XCTAssertNil(c.syncTopic)
        XCTAssertNil(c.historyDays)
        XCTAssertNil(c.apps[0].icon)
        XCTAssertNil(c.apps[0].sound)
        XCTAssertNil(c.apps[0].topics[0].sound)
        XCTAssertNil(c.apps[0].topics[0].name)

        let empty = try JSONDecoder().decode(Catalog.self, from: Data(#"{"version":5}"#.utf8))
        XCTAssertEqual(empty.apps, [])
    }

    func testDecodesAdminFieldsWithoutFailing() throws {
        let json = #"{"version":1,"apps":[{"id":"a","name":"A","icon":"","sound":"urgent","locked":true,"#
            + #""topics":[{"topic":"a-x","name":"X","sound":"urgent","permission":"read-write","hidden":true,"locked":false}]}]}"#
        let c = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.apps[0].topics[0].sound, "urgent")
    }

    func testOldSettingsStillDecode() throws {
        // settings as saved by ntfy-bar 1.0 (and a topic saved before `enabled` existed)
        let v1 = #"{"serverURL":"https://ntfy.kudcrafts.com","username":"hammas","#
            + #""topics":[{"name":"deploys","muted":true,"enabled":false},{"name":"alerts"}],"soundForAll":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(v1.utf8))
        XCTAssertEqual(s.topicNames, ["deploys", "alerts"])
        XCTAssertTrue(s.topics[0].muted)
        XCTAssertFalse(s.topics[0].enabled)
        XCTAssertTrue(s.topics[1].enabled)
        XCTAssertNil(s.topics[0].managed)
        XCTAssertNil(s.topics[0].sound)
        XCTAssertNil(s.catalogEnabled)
        XCTAssertNil(s.syncTopic)
        XCTAssertTrue(s.soundForAll)
    }

    func testNewSettingsRoundTrip() throws {
        var s = AppSettings()
        s.serverURL = "https://ntfy.kudcrafts.com"
        s.syncTopic = "st_abc"
        s.catalogEnabled = false
        var t = TopicConfig(name: "facemap-orders")
        t.managed = true
        t.app = "facemap"
        t.appName = "FaceMap"
        t.appIcon = "https://facemap.fyi/icon-192.png"
        t.sound = "alert"
        t.displayName = "Orders"
        s.topics = [t, TopicConfig(name: "plain")]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
        // Unset optionals are not written, so an older build reads the file unchanged.
        let plain = String(decoding: try JSONEncoder().encode(TopicConfig(name: "plain")), as: UTF8.self)
        XCTAssertFalse(plain.contains("managed"))
    }

    // MARK: Reconcile

    private func catalog(_ apps: [Catalog.AppEntry]) -> Catalog { Catalog(version: 1, syncTopic: "st_abc", apps: apps) }

    private var facemap: Catalog.AppEntry {
        Catalog.AppEntry(id: "facemap", name: "FaceMap", icon: "https://facemap.fyi/icon-192.png", sound: "default",
                         topics: [Catalog.TopicEntry(topic: "facemap-orders", name: "Orders", sound: "alert"),
                                  Catalog.TopicEntry(topic: "facemap-alerts", name: nil, sound: "default")])
    }

    func testReconcileAddsMissingAsManagedEnabledUnmuted() {
        let result = CatalogSync.reconcile(current: [], catalog: catalog([facemap]))
        XCTAssertEqual(result.map(\.name), ["facemap-orders", "facemap-alerts"])
        let orders = result[0]
        XCTAssertEqual(orders.managed, true)
        XCTAssertTrue(orders.enabled)
        XCTAssertFalse(orders.muted)
        XCTAssertEqual(orders.app, "facemap")
        XCTAssertEqual(orders.appName, "FaceMap")
        XCTAssertEqual(orders.appIcon, "https://facemap.fyi/icon-192.png")
        XCTAssertEqual(orders.sound, "alert")
        XCTAssertEqual(orders.displayName, "Orders")
        XCTAssertNil(result[1].displayName)
    }

    func testReconcileUpdatesExistingKeepsUserChoices() {
        var existing = TopicConfig(name: "facemap-orders", muted: true, enabled: false)
        existing.managed = true
        existing.appName = "Old name"
        existing.sound = "urgent"
        let result = CatalogSync.reconcile(current: [existing], catalog: catalog([facemap]))
        XCTAssertEqual(result[0].name, "facemap-orders")
        XCTAssertTrue(result[0].muted)
        XCTAssertFalse(result[0].enabled)
        XCTAssertEqual(result[0].appName, "FaceMap")
        XCTAssertEqual(result[0].sound, "alert")
    }

    func testReconcileDropsManagedNoLongerListed() {
        var gone = TopicConfig(name: "facemap-old")
        gone.managed = true
        let result = CatalogSync.reconcile(current: [gone], catalog: catalog([facemap]))
        XCTAssertFalse(result.map(\.name).contains("facemap-old"))
        XCTAssertEqual(CatalogSync.reconcile(current: [gone], catalog: catalog([])), [])
    }

    func testReconcileNeverTouchesUnmanagedTopicsTheCatalogDoesNotList() {
        let mine = TopicConfig(name: "my-own", muted: true, enabled: false)
        let result = CatalogSync.reconcile(current: [mine], catalog: catalog([facemap]))
        XCTAssertEqual(result.first, mine)
        XCTAssertEqual(CatalogSync.reconcile(current: [mine], catalog: catalog([])), [mine])
    }

    func testReconcileDecoratesUnmanagedListedTopicWithoutManagingIt() {
        // A topic added by hand (e.g. imported from the ntfy CLI) that the catalog also lists:
        // it gets the catalog's app/sound, but stays the user's — it is never removed.
        let mine = TopicConfig(name: "facemap-orders", muted: true)
        let result = CatalogSync.reconcile(current: [mine], catalog: catalog([facemap]))
        XCTAssertEqual(result[0].name, "facemap-orders")
        XCTAssertNil(result[0].managed)
        XCTAssertTrue(result[0].muted)
        XCTAssertEqual(result[0].sound, "alert")
        XCTAssertEqual(result.count, 2)

        let dropped = CatalogSync.reconcile(current: result, catalog: catalog([]))
        XCTAssertEqual(dropped.map(\.name), ["facemap-orders"])
    }

    func testReconcileKeepsOrderAndAppendsNewInCatalogOrder() {
        let existing = [TopicConfig(name: "zzz-mine"), TopicConfig(name: "facemap-alerts")]
        let kud = Catalog.AppEntry(id: "kudtrading", name: "Kudtrading", topics: [Catalog.TopicEntry(topic: "kudtrading")])
        let result = CatalogSync.reconcile(current: existing, catalog: catalog([facemap, kud]))
        XCTAssertEqual(result.map(\.name), ["zzz-mine", "facemap-alerts", "facemap-orders", "kudtrading"])
        XCTAssertEqual(result[3].sound, "default", "missing sound falls back to the default class")
    }

    func testReconcileIsIdempotent() {
        let once = CatalogSync.reconcile(current: [TopicConfig(name: "mine")], catalog: catalog([facemap]))
        XCTAssertEqual(CatalogSync.reconcile(current: once, catalog: catalog([facemap])), once)
    }

    // MARK: Sounds

    func testSoundChoice() {
        // Not a catalog topic: legacy behaviour.
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: nil, soundForAll: false, priority: 3).sound, .off)
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: nil, soundForAll: false, priority: 4).sound, .system)
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: nil, soundForAll: true, priority: 1).sound, .system)
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: "bogus", soundForAll: false, priority: 5).sound, .system)
        // Catalog classes.
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: "silent", soundForAll: true, priority: 5).sound, .off)
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: "default", soundForAll: false, priority: 3).sound, .system)
        XCTAssertEqual(CatalogSync.soundChoice(soundClass: "alert", soundForAll: false, priority: 3).sound,
                       .named("kc_alert.caf"))
        let urgent = CatalogSync.soundChoice(soundClass: "urgent", soundForAll: false, priority: 4)
        XCTAssertEqual(urgent.sound, .named("kc_urgent.caf"))
        XCTAssertTrue(urgent.timeSensitive)
        // Low priority stays quiet, like Android's -low channels.
        let low = CatalogSync.soundChoice(soundClass: "urgent", soundForAll: true, priority: 2)
        XCTAssertEqual(low.sound, .off)
        XCTAssertFalse(low.timeSensitive)
    }

    func testBundledSoundFilesExist() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NtfyBar/Resources/Sounds")
        for cls in SoundClass.allCases {
            guard let file = cls.fileName else { continue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), file)
        }
    }

    // MARK: Sync signal, requests, helpers

    func testSyncSignal() {
        XCTAssertTrue(CatalogSync.isSyncSignal(#"{"event":"sync"}"#))
        XCTAssertTrue(CatalogSync.isSyncSignal(#"{ "event" : "sync", "source": "x" }"#))
        XCTAssertFalse(CatalogSync.isSyncSignal(#"{"event":"other"}"#))
        XCTAssertFalse(CatalogSync.isSyncSignal("sync"))
        XCTAssertFalse(CatalogSync.isSyncSignal(nil))
    }

    func testCatalogRequest() throws {
        let r = try XCTUnwrap(CatalogSync.catalogRequest(base: "https://ntfy.kudcrafts.com", auth: "Bearer tk_x", etag: "\"5\""))
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.kudcrafts.com/v1/catalog")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tk_x")
        XCTAssertEqual(r.value(forHTTPHeaderField: "If-None-Match"), "\"5\"")
        let noTag = try XCTUnwrap(CatalogSync.catalogRequest(base: "https://h", auth: "Bearer tk_x", etag: nil))
        XCTAssertNil(noTag.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNormalizedBase() {
        XCTAssertEqual(CatalogSync.normalizedBase(" https://ntfy.kudcrafts.com// "), "https://ntfy.kudcrafts.com")
        XCTAssertNil(CatalogSync.normalizedBase(""))
        XCTAssertNil(CatalogSync.normalizedBase("not a url"))
    }

    func testBackfillURL() {
        let url = CatalogSync.backfillURL(base: "https://ntfy.kudcrafts.com", topics: ["facemap-orders", "kudtrading"])
        XCTAssertEqual(url?.absoluteString, "https://ntfy.kudcrafts.com/facemap-orders,kudtrading/json?poll=1&since=7d")
        XCTAssertNil(CatalogSync.backfillURL(base: "https://h", topics: []))
    }

    func testParseMessages() {
        let body = """
        {"id":"a1","time":100,"event":"message","topic":"t","message":"hi"}
        {"id":"x","time":101,"event":"keepalive","topic":"t"}
        not json
        {"id":"a2","time":102,"event":"message","topic":"t","title":"T","priority":5}
        """
        let messages = CatalogSync.parseMessages(Data(body.utf8))
        XCTAssertEqual(messages.map(\.id), ["a1", "a2"])
        XCTAssertEqual(messages[1].priority, 5)
    }

    func testParseToken() {
        XCTAssertEqual(CatalogSync.parseToken(Data(#"{"token":"tk_abc","label":"x"}"#.utf8)), "tk_abc")
        XCTAssertNil(CatalogSync.parseToken(Data(#"{"token":"nope"}"#.utf8)))
        XCTAssertNil(CatalogSync.parseToken(Data("garbage".utf8)))
    }

    func testTokenLabel() {
        XCTAssertEqual(CatalogSync.tokenLabel(hostName: "Hammas's MacBook Pro"), "ntfy-bar-Hammas-s-MacBook-Pro")
        XCTAssertEqual(CatalogSync.tokenLabel(hostName: "studio.local"), "ntfy-bar-studio")
        XCTAssertEqual(CatalogSync.tokenLabel(hostName: nil), "ntfy-bar-mac")
    }

    func testCatalogEnabledDefaultAndStreamTopics() {
        var s = AppSettings()
        s.serverURL = "https://ntfy.sh"
        s.topics = [TopicConfig(name: "a"), TopicConfig(name: "b", enabled: false)]
        s.syncTopic = "st_abc"
        XCTAssertFalse(s.isCatalogEnabled)
        XCTAssertEqual(s.streamTopicNames, ["a"])

        s.serverURL = "https://ntfy.kudcrafts.com"
        XCTAssertTrue(s.isCatalogEnabled)
        XCTAssertEqual(s.streamTopicNames, ["a", "st_abc"])
        XCTAssertEqual(s.enabledTopicNames, ["a"], "the sync topic is streamed, never listed")

        s.catalogEnabled = false
        XCTAssertEqual(s.streamTopicNames, ["a"])
    }

    func testGroupedByAppAndLabels() {
        var s = AppSettings()
        s.topics = CatalogSync.reconcile(current: [TopicConfig(name: "mine")], catalog: catalog([facemap]))
        let groups = s.groupedByApp(["facemap-orders", "mine", "facemap-alerts"])
        XCTAssertEqual(groups.map(\.label), ["FaceMap", nil])
        XCTAssertEqual(groups[0].topics, ["facemap-orders", "facemap-alerts"])
        XCTAssertEqual(groups[0].icon, "https://facemap.fyi/icon-192.png")
        XCTAssertEqual(s.label(for: "facemap-orders"), "Orders")
        XCTAssertEqual(s.label(for: "facemap-alerts"), "facemap-alerts")
        XCTAssertEqual(s.label(for: "unknown"), "unknown")
    }
}
