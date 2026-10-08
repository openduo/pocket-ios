// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Messages the user sent from this phone that the room log does not show yet: queued while
/// offline (design Q5), in flight, failed, or delivered and waiting for their log row. A row
/// leaves the outbox when the server's log shows the same `utt_id` (server authority) or when the
/// user deletes it.
public struct OutboxItem: Codable, Equatable, Identifiable, Sendable {
    public enum Body: Codable, Equatable, Sendable {
        /// Typed text with uploaded attachments (each carries the channel `path`).
        case text(String, attachments: [ChannelAttachment])
        /// A phone voice note. The packets live in a side file named by `voiceID`.
        case voice(voiceID: UUID, durationMs: Int)
    }

    public enum State: Codable, Equatable, Sendable {
        /// Waiting for a connection; sent automatically when the channel is reachable.
        case queued
        case sending
        /// Final failure that needs the user (tap to retry). `reason` is user-facing copy.
        case failed(reason: String)
        /// Accepted by the channel; waiting for the log row with this `utt_id`.
        case delivered(uttID: String?, at: String?, transcript: String?, recordAvailable: Bool)
    }

    public var id: UUID
    public var createdAt: Date
    public var body: Body
    public var state: State

    public init(id: UUID = UUID(), createdAt: Date = Date(), body: Body, state: State = .queued) {
        self.id = id
        self.createdAt = createdAt
        self.body = body
        self.state = state
    }

    public var uttID: String? {
        if case .delivered(let u, _, _, _) = state { return u }
        return nil
    }

    public var isVoice: Bool { if case .voice = body { true } else { false } }
}

public struct Outbox: Codable, Equatable, Sendable {
    public private(set) var items: [OutboxItem] = []

    public init(items: [OutboxItem] = []) { self.items = items }

    public mutating func add(_ item: OutboxItem) { items.append(item) }

    public mutating func set(_ id: UUID, _ state: OutboxItem.State) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> OutboxItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// Items to send now that the channel is reachable, oldest first.
    public func sendable() -> [OutboxItem] {
        items.filter { if case .queued = $0.state { true } else { false } }
    }

    /// Drops delivered items whose row is in the server log (by `utt_id`). Returns removed ids.
    @discardableResult
    public mutating func reconcile(with entries: [ImlogEntry]) -> [UUID] {
        let seen = Set(entries.compactMap { $0.isTyped ? $0.utt_id : nil })
        var removed: [UUID] = []
        items.removeAll { item in
            guard let u = item.uttID, seen.contains(u) else { return false }
            removed.append(item.id)
            return true
        }
        return removed
    }

    /// After a launch nothing is in flight: a `sending` item (the app was killed mid-send) becomes
    /// `queued` again. A voice note's retry reuses its voice id, so the channel answers it with the
    /// first result instead of ingressing it twice; a text retry has no such key (see constants.md).
    public mutating func recoverAfterLaunch() {
        for i in items.indices { if case .sending = items[i].state { items[i].state = .queued } }
    }
}

/// Persists the outbox and voice-note packets in one directory. Not thread-safe.
public final class OutboxStore {
    public let directory: URL
    public private(set) var outbox: Outbox
    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: directory.appendingPathComponent("outbox.json")),
           let o = try? dec.decode(Outbox.self, from: d) {
            outbox = o
        } else {
            outbox = Outbox()
        }
        outbox.recoverAfterLaunch()
    }

    public func mutate(_ f: (inout Outbox) -> Void) {
        let before = outbox
        f(&outbox)
        // Voice packets of removed items go with them.
        let kept = Set(outbox.items.map(\.id))
        for gone in before.items where !kept.contains(gone.id) {
            if case .voice(let vid, _) = gone.body { try? fm.removeItem(at: voiceURL(vid)) }
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(outbox) else { return }
        try? d.write(to: directory.appendingPathComponent("outbox.json"), options: .atomic)
    }

    private func voiceURL(_ id: UUID) -> URL { directory.appendingPathComponent("voice-\(id.uuidString.lowercased()).bin") }

    public func saveVoice(_ note: VoiceNote) throws { try note.body().write(to: voiceURL(note.id), options: .atomic) }

    public func loadVoice(_ id: UUID) -> VoiceNote? {
        guard let d = try? Data(contentsOf: voiceURL(id)), let p = try? VoiceNote.packets(fromBody: d) else { return nil }
        return VoiceNote(id: id, source: .phone, packets: p)
    }
}
