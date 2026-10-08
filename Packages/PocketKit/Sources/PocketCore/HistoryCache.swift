// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Offline copy of the room log, one file per room per day (`imlog-YYYY-MM-DD.json`). The server
/// is authoritative: a fetched day replaces its file whole; live `imlog_append` rows are appended
/// to today's copy and replaced at the next fetch. Retention: everything is kept (design Q13).
///
/// Not thread-safe; the owner serialises access (hence `@unchecked Sendable`).
public final class HistoryCache: @unchecked Sendable {
    public let directory: URL
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
        load()
    }

    private func url(_ day: String) -> URL { directory.appendingPathComponent("imlog-\(day).json") }

    private func load() {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        for f in files where f.lastPathComponent.hasPrefix("imlog-") && f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let file = try? dec.decode(DayFile.self, from: d),
                  DayString.isValid(file.day) else { continue }
            days[file.day] = file.entries
            fetchedAt[file.day] = file.fetched_at
        }
    }

    private func save(_ day: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let file = DayFile(day: day, fetched_at: fetchedAt[day], entries: days[day] ?? [])
        guard let d = try? enc.encode(file) else { return }
        try? d.write(to: url(day), options: .atomic)
    }

    /// Cached days, oldest first.
    public var cachedDays: [String] { days.keys.sorted() }

    public func entries(_ day: String) -> [ImlogEntry] { days[day] ?? [] }

    /// The latest server fetch of any cached day (for "显示 HH:MM 缓存的记录").
    public var lastFetch: Date? { fetchedAt.values.max() }

    /// All cached rows, oldest day first, each day in log order.
    public func all() -> [ImlogEntry] { cachedDays.flatMap { days[$0] ?? [] } }

    /// Replaces a day with what the server returned (authoritative).
    public func replace(day: String, entries: [ImlogEntry], at now: Date = Date()) {
        guard DayString.isValid(day) else { return }
        days[day] = entries
        fetchedAt[day] = now
        save(day)
    }

    /// Appends live rows to a day, skipping rows already present (same `key`). Returns the rows
    /// that were new.
    @discardableResult
    public func append(day: String, entries: [ImlogEntry]) -> [ImlogEntry] {
        guard DayString.isValid(day), !entries.isEmpty else { return [] }
        var cur = days[day] ?? []
        var seen = Set(cur.map(\.key))
        var added: [ImlogEntry] = []
        for e in entries where !seen.contains(e.key) {
            seen.insert(e.key)
            cur.append(e)
            added.append(e)
        }
        guard !added.isEmpty else { return [] }
        days[day] = cur
        save(day)
        return added
    }

    /// Forgets everything (room changed).
    public func clear() {
        for d in days.keys { try? fm.removeItem(at: url(d)) }
        days.removeAll()
        fetchedAt.removeAll()
    }
}
