// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// One attachment as the channel names it (`AmbientAttachmentName`); `path` is present only in an
/// upload result, which goes back into a typed message's `attachments`.
public struct ChannelAttachment: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var mime: String
    public var sha256: String?
    public var path: String?

    public init(name: String, mime: String, sha256: String? = nil, path: String? = nil) {
        self.name = name
        self.mime = mime
        self.sha256 = sha256
        self.path = path
    }

    /// The raster formats the channel serves inline (`INLINE_ATTACHMENT_MIME` in http.ts).
    public var isInlineImage: Bool {
        ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
    }
}

/// One row of the room log (`imlog-YYYY-MM-DD.jsonl`, `renderImlogLine` in the channel's store).
/// Rows are append-only and written once. `seq` is the row's cursor; `utt_id` correlates it (a
/// message row's `utt_id` is the message id).
public struct ImlogEntry: Codable, Equatable, Hashable, Sendable {
    /// The room's cursor value for this row. Missing on rows written before the channel had one;
    /// such rows are never replayed by cursor.
    public var seq: Int?
    public var at: String
    public var speaker: String?
    public var kind: String?
    public var text: String
    public var utt_id: String?
    public var attachments: [ChannelAttachment]?
    public var truncated: Bool?
    public var unspoken: Bool?
    public var voice_source: String?
    /// Answer rows: the messages the answer's turn covered.
    public var message_ids: [String]?
    /// Truncated answer rows: the whole answer (`text` is the part that was heard).
    public var full_text: String?

    public init(seq: Int? = nil, at: String, speaker: String? = nil, kind: String? = nil, text: String,
                utt_id: String? = nil, attachments: [ChannelAttachment]? = nil, truncated: Bool? = nil,
                unspoken: Bool? = nil, voice_source: String? = nil, message_ids: [String]? = nil,
                full_text: String? = nil) {
        self.seq = seq
        self.at = at
        self.speaker = speaker
        self.kind = kind
        self.text = text
        self.utt_id = utt_id
        self.attachments = attachments
        self.truncated = truncated
        self.unspoken = unspoken
        self.voice_source = voice_source
        self.message_ids = message_ids
        self.full_text = full_text
    }

    /// The text a surface shows: the whole answer for a truncated row, else `text`.
    public var shownText: String { full_text ?? text }

    /// Speaker label of DuoDuo's own rows (`DUODUO_LABEL` in ambient-protocol).
    public static let duoduoLabel = "多多"

    /// Typed text, a voice note's transcript, or an attachment-only message: addressed to 多多.
    public var isTyped: Bool { kind == "typed" }
    /// Filler speech (「我看看」). Not shown in the thread.
    public var isReaction: Bool { kind == "reaction" }
    /// 多多's answer. Mirrors the web UI's test (`kind === "answer" || speaker === "多多"`).
    public var isAnswer: Bool { !isReaction && (kind == "answer" || speaker == Self.duoduoLabel) }
    /// Overheard room speech (ambient mode).
    public var isHeard: Bool { !isTyped && !isAnswer && !isReaction }

    /// Identity used to merge a row into the cache: its `seq`; rows without one use the web UI's
    /// older rule (`appendImlogEntries` in conversation.js).
    public var key: String {
        if let seq { return "seq:\(seq)" }
        if isTyped, let u = utt_id, !u.isEmpty { return "typed:" + u }
        return "\(at)|\(kind ?? "")|\(text)"
    }

    public static func decodeList(_ any: Any?) -> [ImlogEntry] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            return try? JSONDecoder().decode(ImlogEntry.self, from: d)
        }
    }
}

/// `GET /api/state` fields the app reads.
public struct RoomState: Equatable, Sendable {
    public var room: String
    public var roomName: String
    /// The channel's "today" (its local date), `YYYY-MM-DD`.
    public var date: String
    public var daemonOK: Bool?
    public var cerebellumOK: Bool?
    public var muted: Bool
    /// `limits.upload_max_bytes`. nil when the channel does not publish it (older channel) or when
    /// uploads are disabled (`null`); see `uploadsDisabled`.
    public var uploadMaxBytes: Int?
    /// True when the channel published `limits` with a null bound: upload and voice are off.
    public var uploadsDisabled: Bool
    public var configIssues: [String]
    /// `cerebellum_halt` with reason `protocol`: the channel and its cerebellum speak different
    /// majors, and both must be upgraded together.
    public var cerebellumMismatch: Bool

    public init(room: String = "", roomName: String = "", date: String = "", daemonOK: Bool? = nil,
                cerebellumOK: Bool? = nil, muted: Bool = false, uploadMaxBytes: Int? = nil, uploadsDisabled: Bool = false,
                configIssues: [String] = [], cerebellumMismatch: Bool = false) {
        self.cerebellumMismatch = cerebellumMismatch
        self.room = room
        self.roomName = roomName
        self.date = date
        self.daemonOK = daemonOK
        self.cerebellumOK = cerebellumOK
        self.muted = muted
        self.uploadMaxBytes = uploadMaxBytes
        self.uploadsDisabled = uploadsDisabled
        self.configIssues = configIssues
    }

    public static func decode(_ body: Data) -> RoomState? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var s = RoomState()
        s.room = o["room"] as? String ?? ""
        s.roomName = o["room_name"] as? String ?? s.room
        s.date = o["date"] as? String ?? ""
        s.daemonOK = o["daemon_ok"] as? Bool
        s.cerebellumOK = o["cerebellum_ok"] as? Bool
        s.muted = ((o["controls"] as? [String: Any])?["mute"] as? [String: Any])?["active"] as? Bool ?? false
        if let limits = o["limits"] as? [String: Any] {
            if let n = limits["upload_max_bytes"] as? Int, n > 0 {
                s.uploadMaxBytes = n
            } else if limits["upload_max_bytes"] is NSNull {
                s.uploadsDisabled = true
            }
        }
        s.configIssues = o["config_issues"] as? [String] ?? []
        s.cerebellumMismatch = (o["cerebellum_halt"] as? [String: Any])?["reason"] as? String == "protocol"
        return s
    }
}

/// `400` from `/api/state` when the room does not exist: the channel lists its rooms.
public struct RoomChoices: Equatable, Sendable {
    public var rooms: [String]
    public var names: [String: String]

    public static func decode(_ body: Data) -> RoomChoices? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let rooms = o["rooms"] as? [String] else { return nil }
        return RoomChoices(rooms: rooms, names: o["room_names"] as? [String: String] ?? [:])
    }
}

/// `POST /api/messages` 202 body: the message id (the `Idempotency-Key` sent) and the channel's
/// accept time. A repeated key answers with the first receipt.
public struct MessageReceipt: Equatable, Sendable {
    public var messageID: String
    public var at: String?

    public init(messageID: String, at: String? = nil) {
        self.messageID = messageID
        self.at = at
    }

    public static func decode(_ body: Data) -> MessageReceipt? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = o["message_id"] as? String else { return nil }
        return MessageReceipt(messageID: id, at: o["at"] as? String)
    }
}

/// `GET /api/imlog?since=` body: the rows after the cursor and the room's cursor.
public struct RowsSince: Equatable, Sendable {
    public var entries: [ImlogEntry]
    public var seq: Int

    public static func decode(_ body: Data) -> RowsSince? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let seq = (o["seq"] as? NSNumber)?.intValue else { return nil }
        return RowsSince(entries: ImlogEntry.decodeList(o["entries"]), seq: seq)
    }
}

/// Paths and bodies of the channel HTTP API (`channel-ambient/src/server/http.ts`).
public enum ChannelPaths {
    static func q(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func state(room: String) -> String { "/api/state?room=" + q(room) }
    public static func imlog(room: String, date: String) -> String { "/api/imlog?room=\(q(room))&date=\(q(date))" }
    public static func imlog(room: String, since: Int) -> String { "/api/imlog?room=\(q(room))&since=\(since)" }
    public static func messages(room: String) -> String { "/api/messages?room=" + q(room) }
    public static func upload(room: String, name: String) -> String { "/api/upload?room=\(q(room))&name=\(q(name))" }
    /// The room's one `/live` connection; `since` asks for the rows after that cursor first.
    public static func live(room: String, since: Int? = nil) -> String {
        "/live?room=" + q(room) + (since.map { "&since=\($0)" } ?? "")
    }

    public static func attachment(room: String, _ a: ChannelAttachment) -> String? {
        guard let sha = a.sha256 else { return nil }
        return "/api/attachment?room=\(q(room))&sha256=\(q(sha))&mime=\(q(a.mime))&name=\(q(a.name))"
    }

    /// Headers of a typed message. The key is the message id; a retry sends the same key.
    public static func typedMessageHeaders(key: String) -> [String: String] {
        ["Content-Type": "application/json", "Idempotency-Key": key]
    }

    /// Typed message body: text plus the upload results (with `path`).
    public static func typedMessageBody(text: String, attachments: [ChannelAttachment]) -> Data {
        var obj: [String: Any] = ["text": text]
        if !attachments.isEmpty {
            obj["attachments"] = attachments.map { a -> [String: Any] in
                var d: [String: Any] = ["name": a.name, "mime": a.mime]
                if let p = a.path { d["path"] = p }
                if let s = a.sha256 { d["sha256"] = s }
                return d
            }
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}

/// The upload size bound (design Q8): the channel publishes `limits.upload_max_bytes` in
/// `/api/state`; an older channel does not, and then its 413 is the only signal.
public enum UploadPolicy {
    public enum Verdict: Equatable {
        case ok
        /// Larger than the published bound; nothing is sent.
        case tooLarge(limit: Int)
        /// The channel publishes a null bound: uploads (and voice notes) are switched off.
        case disabled
    }

    public static func check(size: Int, state: RoomState?) -> Verdict {
        guard let state else { return .ok }
        if state.uploadsDisabled { return .disabled }
        if let limit = state.uploadMaxBytes, size > limit { return .tooLarge(limit: limit) }
        return .ok
    }

    public enum Outcome: Equatable {
        case uploaded(ChannelAttachment)
        /// 413. `limit` is the published bound when known.
        case tooLarge(limit: Int?)
        case disabled
        case failed(String)
    }

    /// Maps an `/api/upload` response.
    public static func outcome(status: Int, body: Data, name: String, mime: String, state: RoomState?) -> Outcome {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        switch status {
        case 200:
            guard let path = o["path"] as? String else { return .failed("no path in upload result") }
            return .uploaded(ChannelAttachment(name: o["name"] as? String ?? name, mime: o["mime"] as? String ?? mime,
                                               sha256: o["sha256"] as? String, path: path))
        case 413:
            return .tooLarge(limit: state?.uploadMaxBytes)
        case 503 where (o["error"] as? String ?? "").contains("upload_max_bytes"):
            return .disabled
        default:
            return .failed("\(status) \(o["error"] as? String ?? "")")
        }
    }

    /// "文件太大（上限 N MB）" text for a limit in bytes; MB with one decimal when below 10.
    public static func limitText(_ bytes: Int?) -> String {
        guard let bytes else { return PocketStrings.fileTooLarge(limitMB: nil) }
        let mb = Double(bytes) / 1_048_576
        let s = mb < 10 ? String(format: "%.1f", mb) : String(Int(mb.rounded()))
        return PocketStrings.fileTooLarge(limitMB: s)
    }
}

/// `YYYY-MM-DD` arithmetic for the per-day room log. Pure calendar math in UTC so the device's
/// time zone never shifts a server date.
public enum DayString {
    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func isValid(_ s: String) -> Bool { fmt.date(from: s).map { fmt.string(from: $0) == s } ?? false }

    public static func adding(_ days: Int, to s: String) -> String? {
        guard let d = fmt.date(from: s), let n = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        return fmt.string(from: n)
    }

    /// Days after `from` up to and including `to`, oldest first.
    public static func range(after from: String, through to: String) -> [String] {
        var out: [String] = []
        var cur = from
        while let next = adding(1, to: cur), next <= to {
            out.append(next)
            cur = next
        }
        return out
    }

    /// Local calendar day of a timestamp, `YYYY-MM-DD`.
    public static func local(_ date: Date, timeZone: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let p = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}
