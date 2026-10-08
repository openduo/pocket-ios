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

/// How a voice note ended, and the RESULT code that tells the Passport.
public enum VoiceOutcome: Equatable, Sendable {
    /// Transcript and the channel's utterance id for reply correlation (docs/ble-protocol.md §8).
    case transcribed(String, uttID: String?)
    case empty
    case asrFailed
    case sendFailed(String)
    case notConnected(String)

    public var resultCode: ResultCode {
        switch self {
        case .transcribed: .transcribed
        case .empty: .empty
        case .asrFailed: .asrFailed
        case .sendFailed: .sendFailed
        case .notConnected: .notConnectedToServer
        }
    }

    public var text: String {
        if case .transcribed(let t, _) = self { return t }
        return ""
    }

    public var uttID: String? {
        if case .transcribed(_, let u) = self { return u }
        return nil
    }
}

public struct VoiceUploadReport: Equatable, Sendable {
    public var outcome: VoiceOutcome
    public var attempts: Int
    /// One entry per attempt: the HTTP status, or the transport error.
    public var trail: [String]
    public var elapsed: TimeInterval

    public init(outcome: VoiceOutcome, attempts: Int, trail: [String], elapsed: TimeInterval) {
        self.outcome = outcome
        self.attempts = attempts
        self.trail = trail
        self.elapsed = elapsed
    }
}

/// Uploads one voice note (ble-protocol §2) and retries it as a unit with the same `X-Voice-Id`,
/// which the channel uses to answer a retry with the first result and never ingress twice.
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
        return "/api/voice?room=" + (room.addingPercentEncoding(withAllowedCharacters: allowed) ?? room)
    }

    public static func headers(for note: VoiceNote) -> [String: String] {
        ["Content-Type": PocketConstants.voiceContentType,
         "X-Voice-Id": note.id.uuidString.lowercased(),
         "X-Voice-Source": note.source.rawValue]
    }

    /// What one response means: a final outcome, or "retry".
    enum Verdict: Equatable { case final(VoiceOutcome), retry(VoiceOutcome) }

    static func verdict(status: Int, body: Data) -> Verdict {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = obj?["error"] as? String ?? ""
        switch status {
        case 200:
            return .final(.transcribed(obj?["text"] as? String ?? "", uttID: obj?["utt_id"] as? String))
        case 422:
            return .final(.empty)
        case 502 where error == "asr_failed":
            return .final(.asrFailed)
        case 503:
            // cerebellum_unavailable: the channel's link to the cerebellum is reconnecting.
            return .retry(.sendFailed("503 \(error)"))
        case 500...599:
            // Safe to repeat: the voice id makes the request idempotent.
            return .retry(.sendFailed("\(status) \(error)"))
        default:
            return .final(.sendFailed("\(status) \(error.isEmpty ? String(decoding: body.prefix(120), as: UTF8.self) : error)"))
        }
    }

    public func upload(_ note: VoiceNote, room: String) async -> VoiceUploadReport {
        let start = now()
        let deadline = start + tuning.uploadDeadline
        var report = VoiceUploadReport(outcome: .sendFailed("not attempted"), attempts: 0, trail: [], elapsed: 0)
        let body: Data
        do { body = try note.body() } catch {
            report.outcome = .sendFailed("body: \(error)")
            return report
        }
        if note.packets.isEmpty {
            report.outcome = .empty
            return report
        }
        var backoff = tuning.uploadBackoffInitial
        while true {
            let remaining = deadline - now()
            if remaining <= 0 { break }
            report.attempts += 1
            do {
                let (status, resBody) = try await transport.send(method: "POST", path: Self.path(room: room),
                                                                 headers: Self.headers(for: note), body: body,
                                                                 timeout: remaining)
                report.trail.append("\(status)")
                switch Self.verdict(status: status, body: resBody) {
                case .final(let o):
                    report.outcome = o
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
