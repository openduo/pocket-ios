// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class SessionViewerTests: XCTestCase {
    private func frame(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func event(_ json: String) throws -> SessionEvent {
        try XCTUnwrap(SessionEvent.decode(try frame(json)))
    }

    private func type(_ f: [String: Any]?) -> String? { f?["type"] as? String }

    func testDecodesSessions() throws {
        let e = try event(#"{"type":"sessions","sessions":[{"key":"k1","name":"写周报","group":"chat","status":"idle","tools":[],"last_event_at":"2026-10-15T08:00:00.000Z"},{"key":"k2","name":"新闻","group":"job","status":"idle","tools":["WebSearch"],"last_event_at":null}]}"#)
        guard case .sessions(let list) = e else { return XCTFail("\(e)") }
        XCTAssertEqual(list.map(\.key), ["k1", "k2"])
        XCTAssertEqual(list[0].group, .chat)
        XCTAssertFalse(list[0].running)
        XCTAssertNotNil(list[0].lastEvent)
        XCTAssertTrue(list[1].running)
        XCTAssertNil(list[1].lastEventAt)
        XCTAssertTrue(SessionSummary(key: "k", name: "n", group: .job, status: "running").running)
    }

    func testRejectsMalformedFrames() throws {
        XCTAssertNil(SessionEvent.decode(try frame(#"{"type":"sessions","sessions":[{"key":"k","name":"n","group":"other","status":"idle","tools":[],"last_event_at":null}]}"#)))
        XCTAssertNil(SessionEvent.decode(try frame(#"{"type":"session_rows","key":"k","rows":[{"id":"1","at":"t","kind":"note"}]}"#)))
        XCTAssertNil(SessionEvent.decode(try frame(#"{"type":"session_rows","key":"k","rows":[{"id":"1","at":"t","kind":"tool","failed":"yes"}]}"#)))
        XCTAssertNil(SessionEvent.decode(try frame(#"{"type":"sessions_error","reason":"other"}"#)))
        XCTAssertNil(SessionEvent.decode(try frame(#"{"type":"row","seq":1}"#)))
        XCTAssertTrue(SessionEvent.isViewerFrame(try frame(#"{"type":"session_rows"}"#)))
        XCTAssertFalse(SessionEvent.isViewerFrame(try frame(#"{"type":"turn"}"#)))
    }

    func testDecodesRowsAndError() throws {
        let e = try event(#"{"type":"session_rows","key":"k","initial":true,"rows":[{"id":"1","at":"2026-10-15T08:00:00Z","kind":"message","text":"hi","from":"other"},{"id":"2","at":"2026-10-15T08:00:01Z","kind":"tool","label":"mcp__srv__Read","input_summary":"{\"file_path\":\"/a/b.md\"}","failed":true}]}"#)
        guard case .rows(let key, let rows, let initial, let gap) = e else { return XCTFail("\(e)") }
        XCTAssertEqual(key, "k")
        XCTAssertTrue(initial)
        XCTAssertFalse(gap)
        XCTAssertEqual(rows[0].from, "other")
        XCTAssertEqual(rows[1].toolLine, "Read /a/b.md")
        XCTAssertTrue(rows[1].failed)
        XCTAssertEqual(try event(#"{"type":"sessions_error","reason":"forbidden"}"#), .error(.forbidden))
    }

    func testToolLineWithPlainSummary() {
        XCTAssertEqual(SessionRow(id: "1", at: "", kind: .tool, label: "Bash", inputSummary: "ls -la").toolLine, "Bash ls -la")
        XCTAssertEqual(SessionRow(id: "1", at: "", kind: .tool, label: "Bash").toolLine, "Bash")
    }

    func testWatchFrames() {
        var s = SessionViewerState()
        let w = s.openDrawer()
        XCTAssertEqual(type(w), "sessions_watch")
        XCTAssertTrue(w?["open"] is NSNull)
        XCTAssertNil(s.openDrawer())
        let o = s.open("k1")
        XCTAssertEqual(o?["open"] as? String, "k1")
        XCTAssertFalse(s.drawerOpen)
        // The drawer opened over an open session changes nothing on the wire.
        XCTAssertNil(s.openDrawer())
        XCTAssertEqual(s.open("k2")?["open"] as? String, "k2")
        XCTAssertNil(s.closeDrawer())
        XCTAssertEqual(type(s.closeSession()), "sessions_unwatch")
        XCTAssertFalse(s.watching)
        XCTAssertEqual(type(s.watchFrame), "sessions_unwatch")

        // Closing the session while the drawer is open keeps the list watched.
        _ = s.openDrawer()
        _ = s.open("k1")
        _ = s.openDrawer()
        let back = s.closeSession()
        XCTAssertEqual(type(back), "sessions_watch")
        XCTAssertTrue(back?["open"] is NSNull)
        XCTAssertEqual(type(s.closeDrawer()), "sessions_unwatch")
    }

    func testListReplacesAndIsDroppedOnLeave() {
        var s = SessionViewerState()
        let list = [SessionSummary(key: "a", name: "A", group: .chat, status: "idle"),
                    SessionSummary(key: "b", name: "B", group: .job, status: "idle")]
        XCTAssertFalse(s.apply(.sessions(list)), "not watching")
        _ = s.openDrawer()
        XCTAssertFalse(s.listed)
        XCTAssertTrue(s.apply(.sessions(list)))
        XCTAssertTrue(s.listed)
        XCTAssertFalse(s.apply(.sessions(list)))
        XCTAssertEqual(s.chats.map(\.key), ["a"])
        XCTAssertEqual(s.jobs.map(\.key), ["b"])
        XCTAssertTrue(s.apply(.sessions([list[1]])))
        XCTAssertEqual(s.sessions.map(\.key), ["b"])
        XCTAssertTrue(s.apply(.error(.unavailable)))
        XCTAssertEqual(s.error, .unavailable)
        XCTAssertTrue(s.apply(.sessions(list)))
        XCTAssertNil(s.error)
        _ = s.closeDrawer()
        XCTAssertTrue(s.sessions.isEmpty)
        XCTAssertFalse(s.listed)
    }

    func testThreadRows() {
        var s = SessionViewerState()
        _ = s.open("k")
        func row(_ id: String, _ kind: SessionRow.Kind = .reply, failed: Bool = false) -> SessionRow {
            SessionRow(id: id, at: "2026-10-15T08:00:00Z", kind: kind, text: id, failed: failed)
        }
        XCTAssertFalse(s.apply(.rows(key: "other", rows: [row("x")], initial: true, gap: false)))
        XCTAssertFalse(s.loaded)
        XCTAssertTrue(s.apply(.rows(key: "k", rows: [row("1"), row("2", .tool)], initial: true, gap: false)))
        XCTAssertTrue(s.loaded)
        XCTAssertEqual(s.items.map(\.id), ["row:1", "row:2"])
        // An overlapping window and a later failure of a shown step replace in place.
        XCTAssertTrue(s.apply(.rows(key: "k", rows: [row("2", .tool, failed: true), row("3")], initial: false, gap: false)))
        XCTAssertEqual(s.items.map(\.id), ["row:1", "row:2", "row:3"])
        guard case .row(let r2) = s.items[1] else { return XCTFail() }
        XCTAssertTrue(r2.failed)
        XCTAssertTrue(s.apply(.rows(key: "k", rows: [row("5")], initial: false, gap: true)))
        XCTAssertEqual(s.items.map(\.id), ["row:1", "row:2", "row:3", "gap:5", "row:5"])
        // A new initial window replaces the thread.
        XCTAssertTrue(s.apply(.rows(key: "k", rows: [], initial: true, gap: false)))
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertTrue(s.loaded)
        // Rows are released when the session is left.
        _ = s.apply(.rows(key: "k", rows: [row("9")], initial: false, gap: false))
        _ = s.closeSession()
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertFalse(s.loaded)
        XCTAssertNil(s.openKey)
    }

    func testSourceRunningAndOrder() {
        func s(_ key: String, _ status: String = "idle", _ at: String? = nil) -> SessionSummary {
            SessionSummary(key: key, name: key, group: key.hasPrefix("job:") ? .job : .chat, status: status, lastEventAt: at)
        }
        XCTAssertEqual(s("lark:oc_1:x").source, .feishu)
        XCTAssertEqual(s("ambient:pocket:x").source, .room)
        XCTAssertEqual(s("job:scan.1").source, .job)
        XCTAssertEqual(s("tether:grok").source, .other("tether"))
        XCTAssertTrue(s("job:a.1", "active").running)
        let ordered = [s("lark:old", "idle", "2026-10-14T00:00:00.000Z"), s("lark:never"),
                       s("lark:new", "idle", "2026-10-15T00:00:00.000Z"), s("lark:busy", "running", "2026-10-01T00:00:00.000Z")]
            .sorted(by: SessionSummary.byActivity).map(\.key)
        XCTAssertEqual(ordered, ["lark:busy", "lark:new", "lark:old", "lark:never"])
    }

    func testToolRowsFoldIntoSteps() {
        func r(_ id: String, _ kind: SessionRow.Kind) -> SessionThreadItem { .row(SessionRow(id: id, at: "t", kind: kind)) }
        let shown = SessionDisplayItem.fold([r("1", .message), r("2", .tool), r("3", .tool), .gap(id: "g"), r("4", .tool), r("5", .reply)])
        XCTAssertEqual(shown.map(\.id), ["row:1", "steps:2", "gap:g", "steps:4", "row:5"])
        guard case .steps(_, let rows) = shown[1] else { return XCTFail("\(shown)") }
        XCTAssertEqual(rows.map(\.id), ["2", "3"])
    }
}
