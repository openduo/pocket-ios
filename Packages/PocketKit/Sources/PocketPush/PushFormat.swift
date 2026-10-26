// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CryptoKit
import Foundation

/// The push contract with the channel (`PUSH_PATH` in `@openduo/ambient-protocol`). The phone
/// makes a random key and registers it with its channel; the channel seals each of 多多's answers
/// with it, and the relay that carries them to APNs can read neither text nor room.
public enum PushFormat {
    /// AES-256-GCM.
    public static let keyBytes = 32
    /// Every sealed message has this size (`PUSH_SEALED_BYTES`).
    public static let sealedBytes = 2934
    /// The additional data of every sealed message (`PUSH_AAD`).
    public static let aad = Data("pocket-push/1".utf8)
    /// The push relay. It alone holds the app's APNs key.
    public static let relay = URL(string: "https://pocket-push.openduo.app")!

    public static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    /// The answer's identifier, in hex: the push's `apns-collapse-id` and the local notification's
    /// request identifier (`pushAnswerIdInput`). Both sides name the same answer, so a push that
    /// follows a local notification replaces it.
    public static func answerID(key: Data, messageIDs: [String], text: String) -> String {
        let input = "pocket-push/answer\n\(messageIDs.sorted().joined(separator: ","))\n\(trim(text))"
        return hmac(key, input)
    }

    /// The room's `thread-id`, in hex (`pushThreadIdInput`).
    public static func threadID(key: Data, room: String) -> String {
        hmac(key, "pocket-push/thread\n\(room)")
    }

    /// The message inside `sealed`, or nil for anything not sealed with `key` in this format.
    public static func open(key: Data, sealed: Data) -> PushMessage? {
        guard key.count == keyBytes, sealed.count == sealedBytes,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        else { return nil }
        // JSON, then zero bytes up to the fixed size.
        let end = plain.firstIndex(of: 0) ?? plain.endIndex
        guard let m = try? JSONDecoder().decode(PushMessage.self, from: plain[plain.startIndex..<end]), m.v == 1
        else { return nil }
        return m
    }

    private static func hmac(_ key: Data, _ input: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// JavaScript's `String.prototype.trim` (the channel's side): white space and line terminators.
    static func trim(_ s: String) -> String {
        let jsSpace: (Unicode.Scalar) -> Bool = { c in
            (c.properties.isWhitespace && c != "\u{85}") || c == "\u{FEFF}"
        }
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !jsSpace($0) }),
              let last = scalars.lastIndex(where: { !jsSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }
}

/// The sealed plaintext (`PushMessage` in `@openduo/ambient-protocol`).
public struct PushMessage: Decodable, Equatable, Sendable {
    public var v: Int
    public var room: String
    /// The answer row's cursor.
    public var seq: Int
    public var messageIDs: [String]
    public var text: String
    /// The channel cut `text` to fit.
    public var cut: Bool

    public init(v: Int, room: String, seq: Int, messageIDs: [String], text: String, cut: Bool) {
        self.v = v; self.room = room; self.seq = seq; self.messageIDs = messageIDs; self.text = text; self.cut = cut
    }

    enum CodingKeys: String, CodingKey {
        case v, room, seq, text, cut
        case messageIDs = "message_ids"
    }
}

/// What the phone remembers between the app and its extension, so one answer alerts once: the
/// answers the app already notified, the row cursor the user has read up to, and the rows already
/// pushed above it.
public struct PushLedger: Codable, Equatable, Sendable {
    public var room: String?
    /// Answer identifiers the app posted local notifications for since it was last in front.
    public var notified: Set<String> = []
    /// The app's row cursor when it was last in front: anything at or below has been seen there.
    public var readSeq: Int = 0
    /// Rows above `readSeq` already pushed.
    public var pushed: Set<Int> = []
    /// Answers shown in notifications since the app was last in front: the app icon's badge. Each
    /// answer counts once, whether the app or a push showed it first.
    public var unread: Int = 0

    public init(room: String? = nil) { self.room = room }

    private enum CodingKeys: String, CodingKey { case room, notified, readSeq, pushed, unread }

    // A ledger written before a field existed decodes with that field's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = try c.decodeIfPresent(String.self, forKey: .room)
        notified = try c.decodeIfPresent(Set<String>.self, forKey: .notified) ?? []
        readSeq = try c.decodeIfPresent(Int.self, forKey: .readSeq) ?? 0
        pushed = try c.decodeIfPresent(Set<Int>.self, forKey: .pushed) ?? []
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }

    public enum Verdict: Equatable, Sendable {
        /// New: alert with sound.
        case alert
        /// Already notified by the app, or already read in the app: shown without sound.
        case quiet
        /// A row already pushed: the channel pushes each row once, so this is a replay. The
        /// placeholder only, without sound.
        case replay
        /// Not this phone's room: the placeholder only.
        case foreign
    }

    /// Decides one arriving push and records it.
    public mutating func admit(_ m: PushMessage, id: String) -> Verdict {
        if let room, m.room != room { return .foreign }
        if pushed.contains(m.seq) { return .replay }
        if m.seq <= readSeq { return .quiet }
        pushed.insert(m.seq)
        return notice(id) ? .alert : .quiet
    }

    /// Records an answer the app shows in a notification. False when it was already shown.
    @discardableResult
    public mutating func notice(_ id: String) -> Bool {
        guard notified.insert(id).inserted else { return false }
        unread += 1
        return true
    }

    /// The app came to the front with its cursor at `cursor`: everything up to it is read, and
    /// the notification centre and the badge are cleared.
    public mutating func read(upTo cursor: Int?) {
        if let cursor, cursor > readSeq { readSeq = cursor }
        pushed = pushed.filter { $0 > readSeq }
        notified = []
        unread = 0
    }
}
