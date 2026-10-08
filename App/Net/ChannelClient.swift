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

    enum StateResult {
        case ok(RoomState)
        /// The room does not exist; the channel listed its rooms.
        case unknownRoom(RoomChoices)
    }

    func state() async throws -> StateResult {
        let (s, b) = try await call("GET", ChannelPaths.state(room: settings.room))
        if s == 200, let st = RoomState.decode(b) { return .ok(st) }
        if s == 400, let c = RoomChoices.decode(b) { return .unknownRoom(c) }
        throw ChannelError.http(s, Self.errorText(b))
    }

    func imlog(date: String) async throws -> [ImlogEntry] {
        let (s, b) = try await call("GET", ChannelPaths.imlog(room: settings.room, date: date))
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
        let o = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any]
        return ImlogEntry.decodeList(o?["entries"])
    }

    func inject(text: String, attachments: [ChannelAttachment]) async throws -> InjectReceipt {
        let (s, b) = try await call("POST", ChannelPaths.inject(room: settings.room),
                                    headers: ["Content-Type": "application/json"],
                                    body: ChannelPaths.injectBody(text: text, attachments: attachments))
        guard s == 200 else { throw ChannelError.http(s, Self.errorText(b)) }
        return InjectReceipt.decode(b)
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
