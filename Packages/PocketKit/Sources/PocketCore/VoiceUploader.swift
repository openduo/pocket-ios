// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// The HTTP leg to the channel. The app implements it over tsnet; tests fake it.
public protocol ChannelTransport: Sendable {
    /// Returns the HTTP status and body, or throws `TransportFailure` when no response arrived.
    func send(method: String, path: String, headers: [String: String], body: Data,
              timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

public enum TransportFailure: Error, Equatable {
    /// The tailnet is not up (not logged in, not Running, no host configured).
    case notConnected(String)
    /// Dial, TLS, timeout or a dropped connection.
    case network(String)
}

/// How a voice note's upload ended. Acceptance (202) is not the transcript: the text and the
/// failures of recognition arrive later as `message` events (`VoiceResultWait`).
public enum VoiceOutcome: Equatable, Sendable {
    /// 202: the channel holds the message under this id (the note's `Idempotency-Key`).
    case accepted(messageID: String)
    case sendFailed(String)
    case notConnected(String)

    /// RESULT for an upload that failed; nil when accepted (RESULT then waits for events).
    public var failureCode: ResultCode? {
        switch self {
        case .accepted: nil
        case .sendFailed: .sendFailed
        case .notConnected: .notConnectedToServer
        }
    }

    public var messageID: String? {
        if case .accepted(let id) = self { return id }
        return nil
    }
}

public struct VoiceUploadReport: Equatable, Sendable {
    public var outcome: VoiceOutcome
    public var attempts: Int
    /// One entry per attempt: the HTTP status, or the transport error.
    public var trail: [String]
    public var elapsed: TimeInterval
    /// Set when the final response says the app or the channel must be upgraded.
    public var upgrade: UpgradeNotice?

    public init(outcome: VoiceOutcome, attempts: Int, trail: [String], elapsed: TimeInterval,
                upgrade: UpgradeNotice? = nil) {
        self.upgrade = upgrade
        self.outcome = outcome
        self.attempts = attempts
        self.trail = trail
        self.elapsed = elapsed
    }
}

/// Uploads one voice note as a message (ble-protocol §2) and retries it as a unit with the same
/// `Idempotency-Key`, which the channel uses to answer a retry with the first receipt and never
/// take the message twice.
public struct VoiceUploader: Sendable {
    public let transport: ChannelTransport
    public let tuning: PocketTuning
    let sleep: @Sendable (TimeInterval) async -> Void
    let now: @Sendable () -> TimeInterval

    public init(transport: ChannelTransport, tuning: PocketTuning,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.tuning = tuning
        self.sleep = sleep
        self.now = now
    }

    public static func path(room: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return "/api/messages?room=" + (room.addingPercentEncoding(withAllowedCharacters: allowed) ?? room)
    }

    /// The note's message id: its UUID, lowercased (the channel lowercases the key on receipt).
    public static func messageID(for note: VoiceNote) -> String { note.id.uuidString.lowercased() }

    public static func headers(for note: VoiceNote, surface: Surface, place: PlaceReport? = nil) -> [String: String] {
        ["Content-Type": PocketConstants.voiceContentType,
         "Idempotency-Key": messageID(for: note),
         "X-Voice-Source": note.source.rawValue].merging(surface.headers) { a, _ in a }
            .merging(place?.headers ?? [:]) { a, _ in a }
    }

    /// What one response means: a final outcome, or "retry".
    enum Verdict: Equatable { case final(VoiceOutcome), retry(VoiceOutcome) }

    static func verdict(status: Int, body: Data, note: VoiceNote) -> Verdict {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = obj?["error"] as? String ?? ""
        switch status {
        case 202:
            return .final(.accepted(messageID: obj?["message_id"] as? String ?? messageID(for: note)))
        case 503:
            // perception_unavailable: the channel's link to the cerebellum is reconnecting.
            return .retry(.sendFailed("503 \(error)"))
        case 500...599:
            // Safe to repeat: the key makes the request idempotent.
            return .retry(.sendFailed("\(status) \(error)"))
        default:
            return .final(.sendFailed("\(status) \(error.isEmpty ? String(decoding: body.prefix(120), as: UTF8.self) : error)"))
        }
    }

    /// Uploads within `within` seconds from now (default `uploadDeadline`; the Passport path passes
    /// what is left of its RESULT deadline). `surface` is the app's surface when the upload began;
    /// `place`, a pending arrival report, rides on every attempt.
    public func upload(_ note: VoiceNote, room: String, within: TimeInterval? = nil,
                       surface: Surface, place: PlaceReport? = nil) async -> VoiceUploadReport {
        let start = now()
        let deadline = start + (within ?? tuning.uploadDeadline)
        var report = VoiceUploadReport(outcome: .sendFailed("not attempted"), attempts: 0, trail: [], elapsed: 0)
        let body: Data
        do { body = try note.body() } catch {
            report.outcome = .sendFailed("body: \(error)")
            return report
        }
        if note.packets.isEmpty {
            report.outcome = .sendFailed("empty note")
            return report
        }
        var backoff = tuning.uploadBackoffInitial
        while true {
            let remaining = deadline - now()
            if remaining <= 0 { break }
            report.attempts += 1
            do {
                let (status, resBody) = try await transport.send(method: "POST", path: Self.path(room: room),
                                                                 headers: Self.headers(for: note, surface: surface, place: place), body: body,
                                                                 timeout: remaining)
                report.trail.append("\(status)")
                switch Self.verdict(status: status, body: resBody, note: note) {
                case .final(let o):
                    report.outcome = o
                    let error = ((try? JSONSerialization.jsonObject(with: resBody)) as? [String: Any])?["error"] as? String
                    report.upgrade = UpgradeNotice.of(status: status, error: error ?? "")
                    report.elapsed = now() - start
                    return report
                case .retry(let o):
                    report.outcome = o
                }
            } catch let f as TransportFailure {
                report.trail.append("\(f)")
                switch f {
                case .notConnected(let why): report.outcome = .notConnected(why)
                case .network(let why): report.outcome = .notConnected(why)
                }
            } catch {
                report.trail.append("\(error)")
                report.outcome = .sendFailed("\(error)")
            }
            let wait = min(backoff, deadline - now())
            if wait <= 0 { break }
            await sleep(wait)
            backoff = min(backoff * 2, tuning.uploadBackoffMax)
        }
        report.elapsed = now() - start
        return report
    }
}
