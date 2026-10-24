import Foundation
import XCTest
@testable import NtfyBar

final class NotificationActionsTests: XCTestCase {
    private func event(_ json: String) throws -> NtfyMessage {
        let e = try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
        return try XCTUnwrap(e.asMessage)
    }

    func testPlainLinkHasNoButtons() throws {
        let m = try event(#"{"event":"message","id":"a","time":1,"topic":"t","message":"hi","click":"https://example.com"}"#)
        XCTAssertNil(m.actions)
        XCTAssertTrue(m.buttonActions.isEmpty)
        XCTAssertEqual(m.openURL?.absoluteString, "https://example.com")
    }

    func testDecodesActionsAsPublishedByNtfy() throws {
        let m = try event("""
        {"event":"message","id":"b","time":1,"topic":"hammas-dev","message":"63 stale",
         "actions":[
           {"id":"x1","action":"http","label":"Delete 63","url":"https://ntfy.kudcrafts.com/hammas-dev-actions",
            "method":"POST","headers":{"Authorization":"Bearer tk_1"},"body":"delete 1 abc","clear":true},
           {"id":"x2","action":"broadcast","label":"Tasker"},
           {"id":"x3","action":"view","label":"Open","url":"https://example.com/a"},
           {"id":"x4","action":"copy","label":"Copy id","value":"abc"},
           {"id":"x5","action":"view","label":"Fifth","url":"https://example.com/b"}
         ]}
        """)
        XCTAssertEqual(m.actions?.count, 5)
        // broadcast is Android-only; the cap is three.
        XCTAssertEqual(m.buttonActions.map(\.label), ["Delete 63", "Open", "Copy id"])
    }

    func testRejectsActionsMacOSCannotRun() {
        XCTAssertFalse(NtfyAction(action: "view", label: "Open", url: "file:///etc/passwd").isSupported)
        XCTAssertFalse(NtfyAction(action: "http", label: "Go", url: "not a url").isSupported)
        XCTAssertFalse(NtfyAction(action: "view", label: "  ", url: "https://example.com").isSupported)
        XCTAssertFalse(NtfyAction(action: "copy", label: "Copy").isSupported)
        XCTAssertTrue(NtfyAction(action: "view", label: "Open", url: "http://example.com").isSupported)
    }

    func testHTTPRequestDefaultsToPOSTWithHeadersAndBody() throws {
        let a = NtfyAction(action: "http", label: "Delete", url: "https://ntfy.kudcrafts.com/x",
                           headers: ["Authorization": "Bearer tk_1"], body: "delete 1 abc")
        let req = try XCTUnwrap(a.httpRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tk_1")
        XCTAssertEqual(req.httpBody.map { String(decoding: $0, as: UTF8.self) }, "delete 1 abc")
    }

    func testGETSendsNoBody() throws {
        let a = NtfyAction(action: "http", label: "Ping", url: "https://example.com", method: "get", body: "x")
        let req = try XCTUnwrap(a.httpRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertNil(req.httpBody)
    }

    func testViewActionHasNoRequest() {
        XCTAssertNil(NtfyAction(action: "view", label: "Open", url: "https://example.com").httpRequest)
    }

    func testButtonIdentifiersRoundTrip() {
        XCTAssertEqual(ActionCategories.buttonIndex(ActionCategories.buttonIdentifier(2)), 2)
        XCTAssertNil(ActionCategories.buttonIndex("com.apple.UNNotificationDefaultActionIdentifier"))
    }

    func testStoredHistoryWithoutActionsStillDecodes() throws {
        let old = #"{"id":"c","time":1,"topic":"t","message":"old entry"}"#
        let m = try JSONDecoder().decode(NtfyMessage.self, from: Data(old.utf8))
        XCTAssertNil(m.actions)
    }
}
