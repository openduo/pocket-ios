// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// What a paired device may do (`AmbientDeviceScope`). `room`: its one bound room. `sessions`:
/// that, plus the read-only session viewer.
public enum DeviceScope: String, Codable, Equatable, Sendable {
    case room
    case sessions
}

/// A pairing link: `duoduopocket://pair?host=<host>&port=<port>&tls=<0|1>&code=<code>`. The
/// channel's pairing command prints it as text and as a QR code.
public struct PairingLink: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var tls: Bool
    /// Single-use pairing code, redeemed with `POST /api/pair`.
    public var code: String

    public init(host: String, port: Int, tls: Bool, code: String) {
        self.host = host
        self.port = port
        self.tls = tls
        self.code = code
    }

    public static let scheme = "duoduopocket"
    /// URL host that selects pairing; every other host of the scheme belongs to the share inbox.
    public static let action = "pair"

    /// Whether a URL of the app's scheme is a pairing link (valid or not).
    public static func isPairURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == action
    }

    /// Parses a pairing link from a URL or from pasted text that contains one (a chat message may
    /// carry words around it). Nil when there is no link, or it lacks a host or a code, or its
    /// port is out of range. A missing port or `tls` takes the `tailscale serve` default (443,
    /// HTTPS).
    public static func parse(_ text: String) -> PairingLink? {
        let prefix = scheme + "://"
        guard let start = text.range(of: prefix, options: .caseInsensitive) else { return nil }
        let tail = text[start.lowerBound...]
        let raw = tail.prefix { !$0.isWhitespace && !"\"'<>“”「」".contains($0) }
        guard let comps = URLComponents(string: String(raw)), comps.host?.lowercased() == action else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
        let host = (q["host"] ?? "").trimmingCharacters(in: .whitespaces)
        let code = (q["code"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !code.isEmpty else { return nil }
        var port = 443
        if let p = q["port"], !p.isEmpty {
            guard let n = Int(p), (1...65535).contains(n) else { return nil }
            port = n
        }
        var tls = true
        if let t = q["tls"]?.lowercased(), !t.isEmpty {
            switch t {
            case "1", "true": tls = true
            case "0", "false": tls = false
            default: return nil
            }
        }
        return PairingLink(host: host, port: port, tls: tls, code: code)
    }

    /// `POST /api/pair` body. A native client asks for the token in the response, so no
    /// `cookie` field.
    public var requestBody: Data {
        (try? JSONSerialization.data(withJSONObject: ["code": code])) ?? Data()
    }
}

/// The device a redeemed code created (`PairResult` with its token).
public struct PairedDevice: Equatable, Sendable {
    public var deviceID: String
    public var name: String
    public var room: String
    public var roomName: String
    public var scope: DeviceScope
    public var token: String

    public init(deviceID: String, name: String, room: String, roomName: String, scope: DeviceScope, token: String) {
        self.deviceID = deviceID
        self.name = name
        self.room = room
        self.roomName = roomName
        self.scope = scope
        self.token = token
    }
}

/// How `POST /api/pair` ended.
public enum PairOutcome: Equatable, Sendable {
    case paired(PairedDevice)
    /// `invalid_code`: expired, already used or unknown. Only a new link helps.
    case invalidCode
    /// 404: the channel predates pairing; it must be upgraded before this app can pair.
    case channelTooOld
    /// Any other answer (`bad_body`, a channel without pairing, a malformed result).
    case failed(String)

    public static let path = "/api/pair"

    public static func of(status: Int, body: Data) -> PairOutcome {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let error = o["error"] as? String
        if error == "invalid_code", status == 400 || status == 401 { return .invalidCode }
        if status == 404 { return .channelTooOld }
        guard status == 200 else { return .failed("\(status) \(error ?? "")") }
        guard let id = o["device_id"] as? String, !id.isEmpty,
              let room = o["room"] as? String, !room.isEmpty,
              let scope = (o["scope"] as? String).flatMap(DeviceScope.init(rawValue:)),
              let token = o["token"] as? String, !token.isEmpty else {
            return .failed("malformed pair result")
        }
        let roomName = (o["room_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? room
        return .paired(PairedDevice(deviceID: id, name: o["name"] as? String ?? "", room: room, roomName: roomName,
                                    scope: scope, token: token))
    }
}

/// The device token on the wire, and the channel's ways of saying it is missing or revoked.
public enum DeviceAuth {
    /// `Authorization` header carrying the token.
    public static func headers(token: String) -> [String: String] { ["Authorization": "Bearer " + token] }

    /// A 401 whose body is `{"error":"unauthorized"}`: the token is missing, unknown or revoked.
    /// Only pairing again helps; the client stops retrying.
    public static func isUnauthorized(status: Int, body: Data) -> Bool {
        guard status == 401 else { return false }
        return ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String == "unauthorized"
    }

    /// `/live` close code for the same condition (`LIVE_CLOSE_UNAUTHORIZED`).
    public static let liveCloseCode = 4401

    /// The bridge reports a close as `close <status>: <reason>`; an unknown status prints as
    /// `StatusCode(4401)`.
    public static func isUnauthorizedClose(_ reason: String) -> Bool {
        reason.hasPrefix("close ") && reason.contains("\(liveCloseCode)")
    }

    /// The bridge's error text when the channel answered the `/live` upgrade with 401
    /// (`ErrLiveUnauthorized` in Bridge/tsbridge/live.go).
    public static let liveOpenUnauthorizedPrefix = "tsbridge: live unauthorized"

    public static func isUnauthorizedOpenError(_ message: String) -> Bool {
        message.hasPrefix(liveOpenUnauthorizedPrefix)
    }

    /// Whether a request to `path` needs the device token. Only the health check and pairing go
    /// without one; the app sends nothing else unpaired (an untokened message is the old app's
    /// request, which the channel answers 410).
    public static func needsToken(path: String) -> Bool {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return p != "/healthz" && p != PairOutcome.path
    }
}
