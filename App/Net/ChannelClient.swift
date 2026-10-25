// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore

enum ChannelError: Error, Equatable, CustomStringConvertible {
    /// No response: tailnet down, dial, TLS or timeout. The message is sent again when online.
    case transport(String)
    /// The channel answered with an error status.
    case http(Int, String)

    var description: String {
        switch self {
        case .transport(let s): "transport: \(s)"
        case .http(let c, let s): "\(c) \(s)"
        }
    }

    var isTransport: Bool { if case .transport = self { true } else { false } }
}

/// Typed calls to the channel HTTP API over tsnet (design §6). Blocking Go calls run on a
/// global queue; callers await.
struct ChannelClient: Sendable {
    let settings: ChannelSettings
    let tuning: PocketTuning

    private var transport: TsnetTransport { TsnetTransport(tuning: tuning) }

    private func call(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data(),
                      timeout: TimeInterval? = nil) async throws -> (Int, Data) {
        do {
            return try await transport.send(method: method, path: path, headers: headers, body: body,
                                            timeout: timeout ?? tuning.connectTimeout)
        } catch let f as TransportFailure {
            switch f {
            case .notConnected(let s), .network(let s): throw ChannelError.transport(s)
            }
        }
    }

    private static func errorText(_ body: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
            ?? String(decoding: body.prefix(120), as: UTF8.self)
    }

    /// `GET /healthz`; returns the round trip in milliseconds.
    func health() async throws -> Int {
        let t0 = CPUClock.uptime()
        let (s, b) = try await call("GET", "/healthz")
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
        return Int((CPUClock.uptime() - t0) * 1000)
    }

    func state() async throws -> RoomState {
        let (s, b) = try await call("GET", ChannelPaths.state(room: settings.room))
        if s == 200, let st = RoomState.decode(b) { return st }
        throw ChannelError.http(s, Self.errorText(b))
    }

    /// `PUT /api/push`: this device's relay grant and sealing key (standard base64).
    func registerPush(grant: String, key: Data) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["grant": grant, "key": key.base64EncodedString()])
        let (s, b) = try await call("PUT", ChannelPaths.push, headers: ["Content-Type": "application/json"], body: body)
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
    }

    /// `POST /api/pair` with the link's code, against the bridge's current target (the caller
    /// points it at the link's host first).
    func pair(_ link: PairingLink) async throws -> PairOutcome {
        let (s, b) = try await call("POST", PairOutcome.path, headers: ["Content-Type": "application/json"],
                                    body: link.requestBody)
        return PairOutcome.of(status: s, body: b)
    }

    func imlog(date: String) async throws -> [ImlogEntry] {
        let (s, b) = try await call("GET", ChannelPaths.imlog(room: settings.room, date: date))
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
        let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
        return ImlogEntry.decodeList(o?["entries"])
    }

    /// `POST /api/messages` with typed text. `key` is the message id; a resend with the same key
    /// gets the first receipt, so a text whose response was lost is not taken twice.
    /// A pending arrival rides along and counts as reported once the message is accepted.
    func sendMessage(text: String, attachments: [ChannelAttachment], key: String) async throws -> MessageReceipt {
        let place = ArrivalMonitor.shared.report()
        let (s, b) = try await call("POST", ChannelPaths.messages(room: settings.room),
                                    headers: ChannelPaths.typedMessageHeaders(key: key, surface: PocketSurface.current(),
                                                                              place: place),
                                    body: ChannelPaths.typedMessageBody(text: text, attachments: attachments))
        ArrivalMonitor.shared.settle(place, accepted: s == 202)
        guard s == 202 else { throw ChannelError.http(s, Self.errorText(b)) }
        return MessageReceipt.decode(b) ?? MessageReceipt(messageID: key, at: nil)
    }

    /// `GET /api/imlog?since=`: the rows after the cursor, without a socket (Background App
    /// Refresh, a BLE wake).
    func rows(since: Int) async throws -> RowsSince {
        let (s, b) = try await call("GET", ChannelPaths.imlog(room: settings.room, since: since))
        guard s == 200, let r = RowsSince.decode(b) else { throw ChannelError.http(s, Self.errorText(b)) }
        return r
    }

    /// `POST /api/upload`. The per-attempt timeout is the upload deadline: a photo over a slow
    /// path takes longer than a control request.
    func upload(name: String, mime: String, data: Data, state: RoomState?) async -> UploadPolicy.Outcome {
        switch UploadPolicy.check(size: data.count, state: state) {
        case .tooLarge(let limit): return .tooLarge(limit: limit)
        case .disabled: return .disabled
        case .ok: break
        }
        do {
            let (s, b) = try await call("POST", ChannelPaths.upload(room: settings.room, name: name),
                                        headers: ["Content-Type": mime], body: data, timeout: tuning.uploadDeadline)
            return UploadPolicy.outcome(status: s, body: b, name: name, mime: mime, state: state)
        } catch {
            return .failed("\(error)")
        }
    }

    func attachment(_ a: ChannelAttachment) async throws -> Data {
        guard let path = ChannelPaths.attachment(room: settings.room, a) else { throw ChannelError.http(404, "no sha256") }
        let (s, b) = try await call("GET", path, timeout: tuning.uploadDeadline)
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
        return b
    }
}
