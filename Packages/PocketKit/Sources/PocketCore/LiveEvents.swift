// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// The `/live` events that carry the cursor and the message lifecycle. `turn`, `answer_final` and
/// the audio plane stay dictionaries; their readers take what they need.
///
/// - `row`: a record row was persisted. Rows are replayed after `since` on connect and then
///   arrive live; only rows carry `seq`.
/// - `ready`: the end of the replay and the room's snapshot: the cursor to store, the open turn,
///   and every message not yet delivered or failed.
/// - `message`: a message's lifecycle, live only. `cleaned` carries the text the brain receives
///   (voice only); `failed` its reason.
public enum LiveEvent: Equatable {
    case ready(Ready)
    case row(seq: Int, ImlogEntry)
    case cleaned(id: String, text: String)
    case failed(id: String, reason: MessageFailure)

    public struct Ready: Equatable, Sendable {
        public var seq: Int
        public var turn: TurnSnapshot?
        /// Messages not yet delivered or failed, by id, with their state (`accepted` or `cleaned`).
        public var messages: [String: String]
        /// The channel's client-API major; nil from a channel that predates it.
        public var api: Int?

        public init(seq: Int, turn: TurnSnapshot? = nil, messages: [String: String] = [:], api: Int? = nil) {
            self.api = api
            self.seq = seq
            self.turn = turn
            self.messages = messages
        }
    }

    /// The open turn in `ready`.
    public struct TurnSnapshot: Equatable, Sendable {
        public var messageIDs: [String]
        public var phase: String

        public init(messageIDs: [String], phase: String) {
            self.messageIDs = messageIDs
            self.phase = phase
        }
    }

    /// Decodes the frame, or nil for every other frame type.
    public static func decode(_ f: [String: Any]) -> LiveEvent? {
        switch f["type"] as? String {
        case "ready":
            guard let seq = (f["seq"] as? NSNumber)?.intValue else { return nil }
            var turn: TurnSnapshot?
            if let t = f["turn"] as? [String: Any] {
                turn = TurnSnapshot(messageIDs: t["message_ids"] as? [String] ?? [], phase: t["phase"] as? String ?? "")
            }
            var messages: [String: String] = [:]
            for m in f["messages"] as? [[String: Any]] ?? [] {
                if let id = m["id"] as? String { messages[id] = m["state"] as? String ?? "accepted" }
            }
            return .ready(Ready(seq: seq, turn: turn, messages: messages, api: (f["api"] as? NSNumber)?.intValue))
        case "row":
            guard let seq = (f["seq"] as? NSNumber)?.intValue,
                  let r = f["row"] as? [String: Any], var e = ImlogEntry.decodeList([r]).first else { return nil }
            e.seq = e.seq ?? seq
            return .row(seq: seq, e)
        case "message":
            guard let id = f["id"] as? String else { return nil }
            switch f["state"] as? String {
            case "cleaned": return .cleaned(id: id, text: f["text"] as? String ?? "")
            case "failed": return .failed(id: id, reason: MessageFailure(rawValue: f["reason"] as? String ?? ""))
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `message_ids` of a `turn` or `answer_final` frame (empty when absent).
    public static func messageIDs(_ f: [String: Any]) -> [String] { f["message_ids"] as? [String] ?? [] }
}

/// Why a message failed (`message failed.reason`).
public enum MessageFailure: Equatable, Sendable {
    case emptyTranscript
    case asrFailed
    case perceptionUnavailable
    /// The row was written and delivery was issued, but the brain could not be reached. The row
    /// stays in the record.
    case brainUnreachable
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "empty_transcript": self = .emptyTranscript
        case "asr_failed": self = .asrFailed
        case "perception_unavailable": self = .perceptionUnavailable
        case "brain_unreachable": self = .brainUnreachable
        default: self = .other(rawValue)
        }
    }
}

/// What a reconnecting client learns about a message it still waits on, from `ready.messages` and
/// the rows it holds (the replay comes before `ready`).
public enum MessageSettlement: Equatable {
    /// Listed in `ready.messages`: still in progress; later transitions arrive live.
    case open(state: String)
    /// Not listed, and its row exists: delivery was issued (or failed after the row was written).
    case logged
    /// Not listed and no row: failed. The reason is not recoverable.
    case failed

    public static func of(_ id: String, ready: LiveEvent.Ready, rowLogged: Bool) -> MessageSettlement {
        if let state = ready.messages[id] { return .open(state: state) }
        return rowLogged ? .logged : .failed
    }
}

/// The room cursor: the `seq` of the newest row this client holds. Rows at or below it are
/// already held and are dropped.
public struct RowCursor: Equatable, Codable, Sendable {
    public private(set) var seq: Int?

    public init(seq: Int? = nil) { self.seq = seq }

    /// Whether a row is new; advances the cursor when it is.
    public mutating func admit(_ rowSeq: Int) -> Bool {
        if let seq, rowSeq <= seq { return false }
        seq = rowSeq
        return true
    }

    /// `ready.seq`, or the `seq` of `GET /api/imlog?since=`: the room's highest persisted row.
    public mutating func reached(_ roomSeq: Int) {
        seq = max(seq ?? roomSeq, roomSeq)
    }
}
