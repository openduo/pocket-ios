// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Offline copy of the room log, one file per room per day (`imlog-YYYY-MM-DD.json`). The server
/// is authoritative: a fetched day replaces its file whole; live `imlog_append` rows go to the
/// day's journal (`imlog-YYYY-MM-DD.jsonl`, one row per line, appended, not rewritten) until the
/// next fetch replaces the day and drops it. Retention: everything is kept (design Q13).
///
/// Not thread-safe; the owner serialises access (hence `@unchecked Sendable`).
public final class HistoryCache: @unchecked Sendable {
    public let directory: URL
    /// Days on disk, from the file names. A day's rows are read the first time they are asked
    /// for: opening the cache costs a directory listing, not every day it holds.
    private var index: Set<String> = []
    private var days: [String: [ImlogEntry]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private let fm = FileManager.default

    struct DayFile: Codable {
        var day: String
        var fetched_at: Date?
        var entries: [ImlogEntry]
    }

    public init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("imlog-") && ["json", "jsonl"].contains(f.pathExtension) {
            let day = String(f.deletingPathExtension().lastPathComponent.dropFirst("imlog-".count))
            if DayString.isValid(day) { index.insert(day) }
        }
    }

    private func url(_ day: String) -> URL { directory.appendingPathComponent("imlog-\(day).json") }
    private func journal(_ day: String) -> URL { directory.appendingPathComponent("imlog-\(day).jsonl") }

    /// Reads a day once: its file, then its journal, whose rows came after the day's last fetch.
    /// A journal line cut short by a crash does not decode and is skipped.
    private func loaded(_ day: String) -> [ImlogEntry] {
        if let d = days[day] { return d }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        var cur: [ImlogEntry] = []
        if let d = try? Data(contentsOf: url(day)), let file = try? dec.decode(DayFile.self, from: d), file.day == day {
            cur = file.entries
            fetchedAt[day] = file.fetched_at
        }
        let j = journal(day)
        if let d = try? Data(contentsOf: j) {
            var seen = Set(cur.map(\.key))
            for line in d.split(separator: UInt8(ascii: "\n")) {
                guard let e = try? dec.decode(ImlogEntry.self, from: Data(line)), !seen.contains(e.key) else { continue }
                seen.insert(e.key)
                cur.append(e)
            }
            // End a cut line, so the next row starts a line of its own.
            if d.last != UInt8(ascii: "\n"), let h = try? FileHandle(forWritingTo: j) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data([UInt8(ascii: "\n")]))
                try? h.close()
            }
        }
        days[day] = cur
        return cur
    }

    private func save(_ day: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let file = DayFile(day: day, fetched_at: fetchedAt[day], entries: days[day] ?? [])
        guard let d = try? enc.encode(file) else { return }
        try? d.write(to: url(day), options: .atomic)
    }

    /// Adds rows to the day's journal: one line each, written at the end of the file.
    private func journal(_ day: String, _ entries: [ImlogEntry]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        var lines = Data()
        for e in entries {
            guard let d = try? enc.encode(e) else { continue }
            lines.append(d)
            lines.append(UInt8(ascii: "\n"))
        }
        let u = journal(day)
        if let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: lines)
        } else {
            try? lines.write(to: u)
        }
    }

    /// Cached days, oldest first.
    public var cachedDays: [String] { index.sorted() }

    public func entries(_ day: String) -> [ImlogEntry] { index.contains(day) ? loaded(day) : [] }

    /// The latest server fetch of the days read so far (for "显示 HH:MM 缓存的记录"); the thread
    /// reads the newest days first, and those were fetched last.
    public var lastFetch: Date? { fetchedAt.values.max() }

    /// All cached rows, oldest day first, each day in log order. Reads every day.
    public func all() -> [ImlogEntry] { cachedDays.flatMap { loaded($0) } }

    /// Replaces a day with what the server returned (authoritative).
    public func replace(day: String, entries: [ImlogEntry], at now: Date = Date()) {
        guard DayString.isValid(day) else { return }
        index.insert(day)
        days[day] = entries
        fetchedAt[day] = now
        save(day)
        try? fm.removeItem(at: journal(day))
    }

    /// Appends live rows to a day, skipping rows already present (same `key`). Returns the rows
    /// that were new.
    @discardableResult
    public func append(day: String, entries: [ImlogEntry]) -> [ImlogEntry] {
        guard DayString.isValid(day), !entries.isEmpty else { return [] }
        var cur = index.contains(day) ? loaded(day) : []
        var seen = Set(cur.map(\.key))
        var added: [ImlogEntry] = []
        for e in entries where !seen.contains(e.key) {
            seen.insert(e.key)
            cur.append(e)
            added.append(e)
        }
        guard !added.isEmpty else { return [] }
        index.insert(day)
        days[day] = cur
        journal(day, added)
        return added
    }

    /// Forgets everything (room changed).
    public func clear() {
        for d in index {
            try? fm.removeItem(at: url(d))
            try? fm.removeItem(at: journal(d))
        }
        index.removeAll()
        days.removeAll()
        fetchedAt.removeAll()
    }
}
