// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// One attachment as the channel names it (`AmbientAttachmentName`); `path` is present only in an
/// upload result, which goes back into `inject.attachments`.
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
public struct ImlogEntry: Codable, Equatable, Hashable, Sendable {
    public var at: String
    public var speaker: String?
    public var kind: String?
    public var text: String
    public var utt_id: String?
    public var attachments: [ChannelAttachment]?
    public var truncated: Bool?
    public var unspoken: Bool?
    public var voice_source: String?

    public init(at: String, speaker: String? = nil, kind: String? = nil, text: String, utt_id: String? = nil,
                attachments: [ChannelAttachment]? = nil, truncated: Bool? = nil, unspoken: Bool? = nil,
                voice_source: String? = nil) {
        self.at = at
        self.speaker = speaker
        self.kind = kind
        self.text = text
        self.utt_id = utt_id
        self.attachments = attachments
        self.truncated = truncated
        self.unspoken = unspoken
        self.voice_source = voice_source
    }

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

    /// Identity used to merge a live append into the cache. Same rule as the web UI
    /// (`appendImlogEntries` in conversation.js).
    public var key: String {
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
    public var imlog: [ImlogEntry]
    /// `limits.upload_max_bytes`. nil when the channel does not publish it (older channel) or when
    /// uploads are disabled (`null`); see `uploadsDisabled`.
    public var uploadMaxBytes: Int?
    /// True when the channel published `limits` with a null bound: upload and voice are off.
    public var uploadsDisabled: Bool
    public var configIssues: [String]

    public init(room: String = "", roomName: String = "", date: String = "", daemonOK: Bool? = nil,
                cerebellumOK: Bool? = nil, muted: Bool = false,
                imlog: [ImlogEntry] = [], uploadMaxBytes: Int? = nil, uploadsDisabled: Bool = false,
                configIssues: [String] = []) {
        self.room = room
        self.roomName = roomName
        self.date = date
        self.daemonOK = daemonOK
        self.cerebellumOK = cerebellumOK
        self.muted = muted
        self.imlog = imlog
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
        s.imlog = ImlogEntry.decodeList(o["imlog"])
        if let limits = o["limits"] as? [String: Any] {
            if let n = limits["upload_max_bytes"] as? Int, n > 0 {
                s.uploadMaxBytes = n
            } else if limits["upload_max_bytes"] is NSNull {
                s.uploadsDisabled = true
            }
        }
        s.configIssues = o["config_issues"] as? [String] ?? []
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

/// `POST /api/inject` 200 body.
public struct InjectReceipt: Equatable, Sendable {
    public var uttID: String?
    public var at: String?
    public var recordAvailable: Bool

    public static func decode(_ body: Data) -> InjectReceipt {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return InjectReceipt(uttID: o["utt_id"] as? String, at: o["at"] as? String,
                             recordAvailable: o["record_available"] as? Bool ?? true)
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
    public static func inject(room: String) -> String { "/api/inject?room=" + q(room) }
    public static func upload(room: String, name: String) -> String { "/api/upload?room=\(q(room))&name=\(q(name))" }
    public static func live(room: String) -> String { "/live?room=" + q(room) }

    public static func attachment(room: String, _ a: ChannelAttachment) -> String? {
        guard let sha = a.sha256 else { return nil }
        return "/api/attachment?room=\(q(room))&sha256=\(q(sha))&mime=\(q(a.mime))&name=\(q(a.name))"
    }

    /// `inject` body: text plus the upload results (with `path`).
    public static func injectBody(text: String, attachments: [ChannelAttachment]) -> Data {
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
