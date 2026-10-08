// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// User-entered connection settings, stored in UserDefaults. Nothing about the channel host or
/// the room is compiled into the app.
struct ChannelSettings: Equatable {
    /// Tailnet name (or address) of the host that publishes the channel.
    var host: String
    var port: Int
    /// HTTPS (the channel published with `tailscale serve`) or plain HTTP.
    var tls: Bool
    var room: String

    /// `tailscale serve` publishes HTTPS on 443.
    static let defaultPort = 443

    var isComplete: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !room.trimmingCharacters(in: .whitespaces).isEmpty }

    static func load(_ d: UserDefaults = .standard) -> ChannelSettings {
        ChannelSettings(host: d.string(forKey: "channel.host") ?? "",
                        port: (d.object(forKey: "channel.port") as? Int) ?? defaultPort,
                        tls: (d.object(forKey: "channel.tls") as? Bool) ?? true,
                        room: d.string(forKey: "channel.room") ?? "")
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(host.trimmingCharacters(in: .whitespaces), forKey: "channel.host")
        d.set(port, forKey: "channel.port")
        d.set(tls, forKey: "channel.tls")
        d.set(room.trimmingCharacters(in: .whitespaces), forKey: "channel.room")
    }

    /// Query-safe room value.
    var roomQuery: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return room.addingPercentEncoding(withAllowedCharacters: allowed) ?? room
    }
}

enum Keys {
    static let savedPeripheral = "ble.peripheral"
    /// Text fingerprints of sent answers, before reply ids were counted. Read once, then removed.
    /// `ReplyTracker.Memory` as JSON: sent answers and the last reply id.
    static let replyMemory = "reply.memory"
    /// Composer input mode: true = hold-to-talk, false = keyboard. Absent = hold-to-talk.
    static let composerVoice = "composer.voice"
}

/// Audio choices from Settings › 声音.
enum AudioPreferences {
    /// Settings key: hold-to-talk records from a connected headset's microphone (true) or the
    /// phone's (false, the default, so AirPods keep A2DP playback).
    static let headsetMicKey = "audio.headsetMic"
    static var headsetMic: Bool { UserDefaults.standard.bool(forKey: headsetMicKey) }
}
