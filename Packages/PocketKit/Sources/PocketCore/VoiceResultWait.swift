// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// The RESULT for one Passport press whose message the channel accepted (202). The text is known
/// only when the channel reports the message `cleaned` on `/live`; RESULT is sent then, not on
/// delivery, because delivery can wait behind earlier room speech (docs/ble-protocol.md §8).
///
/// | Event for the press's message | RESULT |
/// |---|---|
/// | `message cleaned` | 0, the cleaned text (what the brain receives) |
/// | `failed(empty_transcript)` | 1 |
/// | `failed(asr_failed)` | 2 |
/// | `failed(perception_unavailable)` | 3 |
/// | `failed(brain_unreachable)` | none here: it follows RESULT 0 and only ends the reply wait |
/// | reconnect: not in `ready.messages`, its row present | 0, the row's text |
/// | reconnect: not in `ready.messages`, no row | 3 (the reason is not recoverable) |
/// | 202 after the message's row was seen | 0, the row's text |
/// | the deadline passes | 3, or 4 when the `/live` connection is down |
public struct VoiceResultWait: Equatable {
    public let messageID: String
    /// Text of the message's row once seen (it is written with the cleaned text).
    public private(set) var rowText: String?
    public private(set) var done = false

    public init(messageID: String) { self.messageID = messageID }

    public struct Result: Equatable {
        public var code: ResultCode
        public var text: String

        public init(code: ResultCode, text: String) {
            self.code = code
            self.text = text
        }
    }

    /// One `/live` event. Returns the RESULT once, when the event settles the press.
    public mutating func handle(_ event: LiveEvent) -> Result? {
        guard !done else { return nil }
        switch event {
        case .row(_, let e) where e.isTyped && e.utt_id == messageID:
            rowText = e.text
            return nil
        case .cleaned(let id, let text) where id == messageID:
            return finish(.transcribed, text)
        case .failed(let id, let reason) where id == messageID:
            switch reason {
            case .emptyTranscript: return finish(.empty, "")
            case .asrFailed: return finish(.asrFailed, "")
            case .brainUnreachable:
                // Only after the row: the text the brain was sent is the row's.
                return rowText.map { finish(.transcribed, $0) } ?? finish(.sendFailed, "")
            case .perceptionUnavailable, .other: return finish(.sendFailed, "")
            }
        case .ready(let r):
            switch MessageSettlement.of(messageID, ready: r, rowLogged: rowText != nil) {
            case .open: return nil
            case .logged: return finish(.transcribed, rowText ?? "")
            case .failed: return finish(.sendFailed, "")
            }
        default:
            return nil
        }
    }

    /// The upload got its 202. A row already seen means the message was cleaned before the
    /// receipt reached the app (a retry answered with the first receipt after a reconnect): the
    /// row's text is the RESULT. Otherwise the wait goes on.
    public mutating func accepted() -> Result? {
        guard !done, let rowText else { return nil }
        return finish(.transcribed, rowText)
    }

    /// The deadline passed without a settling event.
    public mutating func expired(connected: Bool) -> Result? {
        guard !done else { return nil }
        return finish(connected ? .sendFailed : .notConnectedToServer, "")
    }

    private mutating func finish(_ code: ResultCode, _ text: String) -> Result {
        done = true
        return Result(code: code, text: text)
    }
}
