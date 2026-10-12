// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Messages the user sent from this phone that the room log does not show yet: queued while
/// offline (design Q5), in flight, failed, or accepted and waiting for their log row. Each item is
/// one message with a fixed id, sent as its `Idempotency-Key`, so a resend (after a lost response
/// or a relaunch) is the same message to the channel. An item leaves the outbox when the room log
/// shows a row whose `utt_id` is its message id (server authority) or when the user deletes it.
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
        /// Accepted by the channel (202); waiting for its row. `cleaned` is a voice note's text as
        /// the brain receives it, once the channel reports it.
        case accepted(at: String?, cleaned: String?)
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

    /// The message id: the voice note's id for a voice item, the item id for typed text. The
    /// channel lowercases the key; so does the app.
    public var messageID: String {
        if case .voice(let vid, _) = body { return vid.uuidString.lowercased() }
        return id.uuidString.lowercased()
    }

    public var isAccepted: Bool { if case .accepted = state { true } else { false } }

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

    /// The item with this message id.
    public func item(messageID: String) -> OutboxItem? { items.first { $0.messageID == messageID } }

    /// Drops items whose row is in the server log (`utt_id` = message id). Returns removed ids.
    @discardableResult
    public mutating func reconcile(with entries: [ImlogEntry]) -> [UUID] {
        let seen = Set(entries.compactMap { $0.isTyped ? $0.utt_id : nil })
        var removed: [UUID] = []
        items.removeAll { item in
            guard seen.contains(item.messageID) else { return false }
            removed.append(item.id)
            return true
        }
        return removed
    }

    /// After a launch nothing is in flight: a `sending` item (the app was killed mid-send) becomes
    /// `queued` again. Its resend carries the same key, so the channel answers it with the first
    /// receipt instead of taking it twice.
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
            // No outbox, or one this build cannot read: start empty, without the voice packets
            // of the items that went with it.
            outbox = Outbox()
            for f in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: f)
            }
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
