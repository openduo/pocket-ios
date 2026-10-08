// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// One row of the conversation as the screen shows it (design §4.3).
public enum ThreadRow: Identifiable, Equatable, Sendable {
    case separator(id: String, label: String)
    case mine(Mine)
    case duoduo(Duoduo)
    case heard(Heard)
    case pending(OutboxItem)
    case working(TurnState.Working)
    /// A live answer whose log row has not arrived. `id` is the row id it shares with that log
    /// row (`ans:<utt_id>`), so the bubble is updated in place when the row lands.
    case provisional(TurnState.Provisional, id: String)

    public struct Mine: Equatable, Sendable {
        public var id: String
        public var text: String
        public var at: Date?
        /// "phone" / "passport" for a voice note's transcript.
        public var voiceSource: String?
        /// Known for voice notes this phone uploaded (Passport or hold-to-talk).
        public var durationMs: Int?
        public var attachments: [ChannelAttachment]
        /// Meta under the bubble: 已送达, or 已送达，记录未保存.
        public var delivery: String?
    }

    public struct Duoduo: Equatable, Sendable {
        public var id: String
        public var text: String
        public var at: Date?
        /// 已播报 / 只播了一部分 / nil (unspoken, or not an ambient answer).
        public var spoken: String?
        /// Time under the bubble, shown on the last row of a run of 多多 rows.
        public var showTime: Bool
        public var trace: TurnState.Trace
        /// Files 多多 sent. The channel records them as their own row with no text.
        public var attachments: [ChannelAttachment] = []
    }

    public struct Heard: Equatable, Sendable {
        public struct Line: Equatable, Sendable {
            public var speaker: String?
            public var text: String
        }
        public var id: String
        /// Visible lines, oldest first.
        public var lines: [Line]
        /// Earlier lines folded into "房间里还说了 N 句".
        public var folded: [Line]
    }

    public var id: String {
        switch self {
        case .separator(let id, _): id
        case .mine(let m): m.id
        case .duoduo(let d): d.id
        case .heard(let h): h.id
        case .pending(let p): "pending:" + p.id.uuidString
        case .working: "working"
        case .provisional(_, let id): id
        }
    }
}

/// Builds thread rows from the server log plus local state. Pure: the same inputs give the same
/// rows, so the cache, the live socket and the outbox can never disagree on what is shown.
public struct ThreadBuilder {
    /// A time separator appears when this much time passed between rows (design §4.3, display
    /// only).
    public static let separatorGap: TimeInterval = 10 * 60
    /// A run of overheard room speech longer than this folds its earlier lines (design Q6: "runs
    /// of more than 3 fold").
    public static let heardRunVisible = 3

    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }

    public struct Input {
        public var entries: [ImlogEntry]
        public var outbox: [OutboxItem]
        public var turn: TurnState
        /// Voice-note durations by `utt_id`, for notes this phone uploaded.
        public var durations: [String: Int]
        /// `record_unavailable` utterances seen live.
        public var recordLost: Set<String>
        /// Live-only room notes ("听到了，不是在叫我").
        public var notes: [(at: Date, text: String)]

        public init(entries: [ImlogEntry], outbox: [OutboxItem] = [], turn: TurnState = TurnState(),
                    durations: [String: Int] = [:], recordLost: Set<String> = [], notes: [(at: Date, text: String)] = []) {
            self.entries = entries
            self.outbox = outbox
            self.turn = turn
            self.durations = durations
            self.recordLost = recordLost
            self.notes = notes
        }
    }

    private enum Item {
        case entry(ImlogEntry, Date?)
        case note(Date, String)
        case provisional(TurnState.Provisional)
        var at: Date? {
            switch self {
            case .entry(_, let d): d
            case .note(let d, _): d
            case .provisional(let p): p.at
            }
        }
    }

    public func build(_ input: Input) -> [ThreadRow] {
        var items: [Item] = input.entries.filter { !$0.isReaction }.map { .entry($0, Self.parse($0.at)) }
        for n in input.notes { items.append(.note(n.at, n.text)) }
        // A live answer sits where it arrived, as the log will put its row: rows logged after it
        // (a later question) come below it, live and after a catch-up alike. One whose text is
        // already logged is settled; it is not shown twice.
        let loggedAnswers = Set(input.entries.filter(\.isAnswer).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        for p in input.turn.provisional where !loggedAnswers.contains(p.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            items.append(.provisional(p))
        }
        // The log is in order per day; notes and live answers are interleaved by time (the phone
        // and the channel host keep network time). A stable sort keeps rows without a parseable
        // time where the log put them.
        items = items.enumerated().sorted { a, b in
            switch (a.element.at, b.element.at) {
            case let (x?, y?) where x != y: return x < y
            default: return a.offset < b.offset
            }
        }.map(\.element)

        var rows: [ThreadRow] = []
        var lastAt: Date?
        var heardRun: [ThreadRow.Heard.Line] = []
        var heardID = ""
        var lastMineIndex: Int?
        // `ans:<utt_id>` names the first answer to an utterance, live or logged, so the live bubble
        // and its log row are one row to the list (no remove and insert of a long bubble).
        var answerIDs = Set<String>()
        func answerID(_ utt: String?, fallback: String) -> String {
            guard let utt, !utt.isEmpty, answerIDs.insert(utt).inserted else { return fallback }
            return "ans:" + utt
        }

        func flushHeard() {
            guard !heardRun.isEmpty else { return }
            let cut = max(0, heardRun.count - Self.heardRunVisible)
            rows.append(.heard(.init(id: heardID, lines: Array(heardRun[cut...]), folded: Array(heardRun[..<cut]))))
            heardRun = []
        }

        func separate(_ at: Date?) {
            guard let at else { return }
            if let prev = lastAt, sameDay(prev, at), at.timeIntervalSince(prev) < Self.separatorGap {
                lastAt = at
                return
            }
            let dayChanged = lastAt.map { !sameDay($0, at) } ?? true
            flushHeard()
            rows.append(.separator(id: "sep:\(at.timeIntervalSince1970)", label: label(at, withDay: dayChanged)))
            lastAt = at
        }

        for item in items {
            separate(item.at)
            switch item {
            case .provisional(let p):
                flushHeard()
                rows.append(.provisional(p, id: answerID(p.uttID, fallback: "prov:\(p.at.timeIntervalSince1970)")))
            case .note(let at, let text):
                if heardRun.isEmpty { heardID = "note:\(at.timeIntervalSince1970)" }
                heardRun.append(.init(speaker: nil, text: text))
            case .entry(let e, let at):
                if e.isHeard {
                    if heardRun.isEmpty { heardID = "heard:\(e.key)" }
                    // `V?` is the unknown-speaker label (`UNKNOWN_SPEAKER_LABEL` in ambient-protocol).
                    let speaker = e.speaker.flatMap { $0 == "V?" ? nil : $0 }
                    heardRun.append(.init(speaker: speaker, text: e.text))
                    continue
                }
                flushHeard()
                if e.isTyped {
                    // A delivered outbox item still shows as pending until reconcile removes it;
                    // its log row replaces it here, so do not show both.
                    var delivery: String?
                    if let u = e.utt_id, input.recordLost.contains(u) { delivery = PocketStrings.deliveredNotLogged() }
                    rows.append(.mine(.init(id: "mine:\(e.key)", text: e.text, at: at, voiceSource: e.voice_source,
                                            durationMs: e.utt_id.flatMap { input.durations[$0] },
                                            attachments: e.attachments ?? [], delivery: delivery)))
                    lastMineIndex = rows.count - 1
                } else {
                    let files = e.attachments ?? []
                    let filesOnly = !files.isEmpty && e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    // A row of files was never spoken; 已播报 would be false.
                    let spoken: String? = e.unspoken == true || filesOnly ? nil : (e.truncated == true ? PocketStrings.partlySpoken() : PocketStrings.spoken())
                    let id = filesOnly ? "duo:\(e.key)" : answerID(e.utt_id, fallback: "duo:\(e.key)")
                    rows.append(.duoduo(.init(id: id, text: e.text, at: at, spoken: spoken, showTime: true,
                                              trace: filesOnly ? .empty : input.turn.trace(forAnswer: e.text, uttID: e.utt_id),
                                              attachments: files)))
                }
            }
        }
        flushHeard()

        // Pending rows: everything in the outbox whose log row has not arrived.
        let logged = Set(input.entries.compactMap { $0.isTyped ? $0.utt_id : nil })
        for p in input.outbox where !(p.uttID.map(logged.contains) ?? false) {
            rows.append(.pending(p))
        }
        if let w = input.turn.working {
            rows.append(.working(w))
        }

        // "已送达" sits under my last logged row when nothing of mine is pending after it.
        if let i = lastMineIndex, case .mine(var m) = rows[i], m.delivery == nil,
           !rows[(i + 1)...].contains(where: { if case .mine = $0 { true } else if case .pending = $0 { true } else { false } }) {
            m.delivery = PocketStrings.delivered()
            rows[i] = .mine(m)
        }
        // Time under 多多 bubbles only on the last of a run.
        for i in rows.indices {
            guard case .duoduo(var d) = rows[i] else { continue }
            let next = rows.indices.contains(i + 1) ? rows[i + 1] : nil
            if case .duoduo = next { d.showTime = false; rows[i] = .duoduo(d) }
        }
        return rows
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    private func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    func label(_ at: Date, withDay: Bool) -> String {
        let c = calendar
        let hm = String(format: "%02d:%02d", c.component(.hour, from: at), c.component(.minute, from: at))
        guard withDay else { return hm }
        if c.isDate(at, inSameDayAs: now) { return PocketStrings.today(hm) }
        if let y = c.date(byAdding: .day, value: -1, to: now), c.isDate(at, inSameDayAs: y) { return PocketStrings.yesterday(hm) }
        let p = c.dateComponents([.year, .month, .day], from: at)
        if p.year == c.component(.year, from: now) { return PocketStrings.monthDay(p.month ?? 0, p.day ?? 0, hm) }
        return PocketStrings.yearMonthDay(p.year ?? 0, p.month ?? 0, p.day ?? 0, hm)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    /// Parses the channel's ISO 8601 timestamps (with or without fractional seconds).
    public static func parse(_ s: String) -> Date? {
        isoLock.lock(); defer { isoLock.unlock() }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
}
