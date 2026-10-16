// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// A session in the viewer's list (`AmbientSessionSummary`).
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public enum Group: String, Equatable, Sendable {
        case chat
        case job
    }

    public var key: String
    public var name: String
    public var group: Group
    /// The daemon's status word (for example `idle`, `running`).
    public var status: String
    /// Tools running right now; empty when none.
    public var tools: [String]
    public var lastEventAt: String?
    /// The session accepts a notification: a chat session, or a job kept alive between runs.
    public var notify: Bool

    public init(key: String, name: String, group: Group, status: String, tools: [String] = [], lastEventAt: String? = nil,
                notify: Bool = false) {
        self.key = key
        self.name = name
        self.group = group
        self.status = status
        self.tools = tools
        self.lastEventAt = lastEventAt
        self.notify = notify
    }

    public var id: String { key }

    /// A tool runs, or the daemon says the session runs (`running`, or `active` for a job).
    public var running: Bool { !tools.isEmpty || ["running", "active"].contains(status.lowercased()) }

    /// Where the session lives, from its key's prefix (`lark:…`, `job:…`).
    public enum Source: Equatable, Sendable {
        case feishu
        case room
        case job
        case other(String)
    }

    public var source: Source {
        let parts = key.split(separator: ":", maxSplits: 1)
        let prefix = parts.count == 2 ? String(parts[0]) : ""
        switch prefix {
        case "lark", "feishu": return .feishu
        case "ambient": return .room
        case "job": return .job
        default: return .other(prefix)
        }
    }

    /// Drawer order: running first, then the latest activity; never-active sessions last.
    static func byActivity(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
        if a.running != b.running { return a.running }
        return (a.lastEvent ?? .distantPast) > (b.lastEvent ?? .distantPast)
    }

    public var lastEvent: Date? { lastEventAt.flatMap(ThreadBuilder.parse) }

    static func decode(_ o: [String: Any]) -> SessionSummary? {
        guard let key = o["key"] as? String, let name = o["name"] as? String,
              let group = (o["group"] as? String).flatMap(Group.init(rawValue:)),
              let status = o["status"] as? String, let tools = o["tools"] as? [String] else { return nil }
        let last = o["last_event_at"]
        guard last == nil || last is NSNull || last is String else { return nil }
        if let n = o["notify"], !(n is Bool) { return nil }
        return SessionSummary(key: key, name: name, group: group, status: status, tools: tools, lastEventAt: last as? String,
                              notify: o["notify"] as? Bool ?? false)
    }
}

/// One row of an opened session (`AmbientSessionRow`).
public struct SessionRow: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// A message that entered the session; `from` names the sending session.
        case message
        /// The session's answer (Markdown).
        case reply
        /// A tool step: `label` the tool name, `inputSummary` its input.
        case tool
        /// A command receipt or a job start.
        case system
        /// A notification delivered from elsewhere: `from` the sending session, `fromLabel` the
        /// sender as it named itself.
        case notify
    }

    public var id: String
    public var at: String
    public var kind: Kind
    public var text: String?
    public var from: String?
    public var label: String?
    public var inputSummary: String?
    public var failed: Bool
    public var fromLabel: String?

    public init(id: String, at: String, kind: Kind, text: String? = nil, from: String? = nil, label: String? = nil,
                inputSummary: String? = nil, failed: Bool = false, fromLabel: String? = nil) {
        self.fromLabel = fromLabel
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
        self.from = from
        self.label = label
        self.inputSummary = inputSummary
        self.failed = failed
    }

    public var date: Date? { ThreadBuilder.parse(at) }

    /// A tool row as the room thread's step line: `<name> <summary>` (`ToolLine`).
    public var toolLine: String {
        TurnState.Step(name: ToolLine.displayName(label ?? ""), summary: ToolLine.summarize(inputSummary)).line
    }

    static func decode(_ o: [String: Any]) -> SessionRow? {
        guard let id = o["id"] as? String, let at = o["at"] as? String,
              let kind = (o["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        for k in ["text", "from", "label", "input_summary", "from_label"] where o[k] != nil && !(o[k] is String) { return nil }
        if let f = o["failed"], !(f is Bool) { return nil }
        return SessionRow(id: id, at: at, kind: kind, text: o["text"] as? String, from: o["from"] as? String,
                          label: o["label"] as? String, inputSummary: o["input_summary"] as? String,
                          failed: o["failed"] as? Bool ?? false, fromLabel: o["from_label"] as? String)
    }
}

/// Why a notification was not delivered (`session_notify_result`).
public enum NotifyFailure: String, Equatable, Sendable {
    /// The device lacks the `notify` scope.
    case forbidden
    /// The session does not take notifications.
    case notNotifiable = "not_notifiable"
    /// The daemon no longer has the session.
    case notFound = "not_found"
    case failed
}

public enum NotifyOutcome: Equatable, Sendable {
    case sent
    case failed(NotifyFailure)
}

/// The uplink frame that sends a notification to session `key`; `id` correlates the result.
public func sessionNotifyFrame(id: String, key: String, text: String) -> [String: Any] {
    ["type": "session_notify", "id": id, "key": key, "text": text]
}

/// Why the viewer is not available on this connection (`sessions_error`).
public enum SessionsError: String, Equatable, Sendable {
    /// The device lacks the `sessions` scope.
    case forbidden
    /// The daemon could not be read; the channel keeps trying.
    case unavailable
}

/// The session viewer's downlink frames on `/live`.
public enum SessionEvent: Equatable, Sendable {
    /// The whole list; it replaces the shown one.
    case sessions([SessionSummary])
    /// Rows of the open session. `initial`: the window read when it was opened (replaces the
    /// thread). `gap`: the daemon skipped events before these rows.
    case rows(key: String, rows: [SessionRow], initial: Bool, gap: Bool)
    case error(SessionsError)
    /// The channel's answer to a `session_notify`; `reason` is nil when it was delivered.
    case notifyResult(id: String, reason: NotifyFailure?)

    /// Decodes a viewer frame; nil for any other frame or a malformed one.
    public static func decode(_ f: [String: Any]) -> SessionEvent? {
        switch f["type"] as? String {
        case "sessions":
            guard let arr = f["sessions"] as? [[String: Any]] else { return nil }
            let list = arr.compactMap(SessionSummary.decode)
            return list.count == arr.count ? .sessions(list) : nil
        case "session_rows":
            guard let key = f["key"] as? String, let arr = f["rows"] as? [[String: Any]] else { return nil }
            let rows = arr.compactMap(SessionRow.decode)
            guard rows.count == arr.count else { return nil }
            return .rows(key: key, rows: rows, initial: f["initial"] as? Bool ?? false, gap: f["gap"] as? Bool ?? false)
        case "sessions_error":
            return (f["reason"] as? String).flatMap(SessionsError.init(rawValue:)).map { .error($0) }
        case "session_notify_result":
            guard let id = f["id"] as? String, let ok = f["ok"] as? Bool else { return nil }
            if ok { return .notifyResult(id: id, reason: nil) }
            return (f["reason"] as? String).flatMap(NotifyFailure.init(rawValue:)).map { .notifyResult(id: id, reason: $0) }
        default:
            return nil
        }
    }

    /// Whether a frame type belongs to the viewer (so it is not handed to the room thread).
    public static func isViewerFrame(_ f: [String: Any]) -> Bool {
        ["sessions", "session_rows", "sessions_error", "session_notify_result"].contains(f["type"] as? String ?? "")
    }
}

/// One item of an opened session's thread.
public enum SessionThreadItem: Identifiable, Equatable, Sendable {
    case row(SessionRow)
    /// The daemon skipped events here (「此处有未显示的事件」).
    case gap(id: String)

    public var id: String {
        switch self {
        case .row(let r): "row:" + r.id
        case .gap(let id): "gap:" + id
        }
    }
}

/// The viewer's state: what the drawer and the opened session show, and which watch frame the
/// channel must have. Pure; the app sends the frames it returns on `/live`.
///
/// The channel watches while the drawer is open or a session is open: `sessions_watch` with the
/// open key (or null), sent again whenever that changes and after every `/live` reconnect.
/// `sessions_unwatch` once both are closed. An opened session's rows live here only while it is
/// open.
public struct SessionViewerState: Equatable, Sendable {
    public private(set) var drawerOpen = false
    public private(set) var openKey: String?
    public private(set) var sessions: [SessionSummary] = []
    /// A list arrived since the watch started (an empty list is then "no sessions").
    public private(set) var listed = false
    /// The open session's thread, oldest first.
    public private(set) var items: [SessionThreadItem] = []
    /// The open session's initial window arrived.
    public private(set) var loaded = false
    public private(set) var error: SessionsError?
    /// A notification sent and not yet answered (its correlation id).
    public private(set) var pendingNotify: String?
    /// The last answered notification. Cleared by the next send.
    public private(set) var notifyOutcome: NotifyOutcome?

    public init() {}

    /// Sends `text` to the open session when it takes notifications; returns the frame, or nil
    /// when nothing may be sent (no session open, it does not accept, empty text, one in flight).
    public mutating func notify(_ text: String, id: String) -> [String: Any]? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = openSession, s.notify, !body.isEmpty, pendingNotify == nil else { return nil }
        pendingNotify = id
        notifyOutcome = nil
        return sessionNotifyFrame(id: id, key: s.key, text: body)
    }

    /// The outcome was shown; the next sheet starts clean.
    public mutating func clearNotifyOutcome() { notifyOutcome = nil }

    /// The connection that would carry the result is gone: settle the send as failed, as the
    /// page does, so another can be sent. It may still have been delivered.
    public mutating func dropPendingNotify() {
        guard pendingNotify != nil else { return }
        pendingNotify = nil
        notifyOutcome = .failed(.failed)
    }

    public var watching: Bool { drawerOpen || openKey != nil }

    public var chats: [SessionSummary] { sessions.filter { $0.group == .chat }.sorted(by: SessionSummary.byActivity) }
    public var jobs: [SessionSummary] { sessions.filter { $0.group == .job }.sorted(by: SessionSummary.byActivity) }
    public var openSession: SessionSummary? { openKey.flatMap { k in sessions.first { $0.key == k } } }

    /// The uplink frame that states the current watch: `sessions_watch` while watching, else
    /// `sessions_unwatch`.
    public var watchFrame: [String: Any] {
        guard watching else { return ["type": "sessions_unwatch"] }
        return ["type": "sessions_watch", "open": openKey.map { $0 as Any } ?? NSNull()]
    }

    /// Opens the drawer; returns the frame to send, nil when nothing changed on the wire.
    public mutating func openDrawer() -> [String: Any]? {
        guard !drawerOpen else { return nil }
        let was = watching
        drawerOpen = true
        return was ? nil : watchFrame
    }

    public mutating func closeDrawer() -> [String: Any]? {
        guard drawerOpen else { return nil }
        drawerOpen = false
        return watching ? nil : leave()
    }

    /// Opens a session (the drawer closes over it).
    public mutating func open(_ key: String) -> [String: Any]? {
        drawerOpen = false
        guard key != openKey else { return nil }
        openKey = key
        items = []
        loaded = false
        return watchFrame
    }

    /// Leaves the open session; back to the room thread.
    public mutating func closeSession() -> [String: Any]? {
        guard openKey != nil else { return nil }
        openKey = nil
        items = []
        loaded = false
        return watching ? watchFrame : leave()
    }

    private mutating func leave() -> [String: Any] {
        sessions = []
        listed = false
        error = nil
        return watchFrame
    }

    /// Applies a downlink event; returns whether anything shown changed.
    public mutating func apply(_ event: SessionEvent) -> Bool {
        switch event {
        case .sessions(let list):
            guard watching else { return false }
            let changed = list != sessions || error != nil || !listed
            sessions = list
            listed = true
            error = nil
            return changed
        case .error(let e):
            guard watching, error != e else { return false }
            error = e
            return true
        case .rows(let key, let rows, let initial, let gap):
            guard key == openKey else { return false }
            if initial {
                items = []
                loaded = true
            }
            if gap, !rows.isEmpty { items.append(.gap(id: rows[0].id)) }
            for r in rows {
                // A row already shown is replaced in place (a tool step that failed later comes
                // again under its id).
                if let i = items.firstIndex(where: { if case .row(let o) = $0 { o.id == r.id } else { false } }) {
                    items[i] = .row(r)
                } else {
                    items.append(.row(r))
                }
            }
            error = nil
            return true
        case .notifyResult(let id, let reason):
            guard id == pendingNotify else { return false }
            pendingNotify = nil
            notifyOutcome = reason.map(NotifyOutcome.failed) ?? .sent
            return true
        }
    }
}

/// What the opened session's thread shows: rows as they are, except that consecutive tool rows
/// fold into one steps item, as a room turn's steps fold above its answer.
public enum SessionDisplayItem: Identifiable, Equatable, Sendable {
    case gap(id: String)
    case row(SessionRow)
    /// Tool rows in order; the id is the first row's, so the item keeps it while steps are added.
    case steps(id: String, rows: [SessionRow])

    public var id: String {
        switch self {
        case .gap(let id): "gap:" + id
        case .row(let r): "row:" + r.id
        case .steps(let id, _): "steps:" + id
        }
    }

    public static func fold(_ items: [SessionThreadItem]) -> [SessionDisplayItem] {
        var out: [SessionDisplayItem] = []
        for item in items {
            switch item {
            case .gap(let id):
                out.append(.gap(id: id))
            case .row(let r) where r.kind == .tool:
                if case .steps(let id, let rows) = out.last {
                    out[out.count - 1] = .steps(id: id, rows: rows + [r])
                } else {
                    out.append(.steps(id: r.id, rows: [r]))
                }
            case .row(let r):
                out.append(.row(r))
            }
        }
        return out
    }
}
