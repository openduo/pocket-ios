// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore

/// Connection settings from pairing, stored in UserDefaults (the token is in the Keychain,
/// `DeviceCredentials`). Nothing about the channel host or the room is compiled into the app.
struct ChannelSettings: Equatable {
    /// Tailnet name (or address) of the host that publishes the channel.
    var host: String
    var port: Int
    /// HTTPS (the channel published with `tailscale serve`) or plain HTTP.
    var tls: Bool
    /// The room the device is bound to; the token names it to the channel.
    var room: String
    var roomName: String = ""
    /// The paired device's id; empty before pairing.
    var deviceID: String = ""
    var scope: DeviceScope = .room

    /// `tailscale serve` publishes HTTPS on 443.
    static let defaultPort = 443

    /// Paired: a host, a room and a device.
    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !room.isEmpty && !deviceID.isEmpty
    }

    /// The room's display name, or its id.
    var roomTitle: String { roomName.isEmpty ? room : roomName }

    static func load(_ d: UserDefaults = .standard) -> ChannelSettings {
        ChannelSettings(host: d.string(forKey: "channel.host") ?? "",
                        port: (d.object(forKey: "channel.port") as? Int) ?? defaultPort,
                        tls: (d.object(forKey: "channel.tls") as? Bool) ?? true,
                        room: d.string(forKey: "channel.room") ?? "",
                        roomName: d.string(forKey: "channel.roomName") ?? "",
                        deviceID: d.string(forKey: "channel.device") ?? "",
                        scope: d.string(forKey: "channel.scope").flatMap(DeviceScope.init(rawValue:)) ?? .room)
    }

    /// The connection a pairing link points at, before its code is redeemed.
    init(link: PairingLink) {
        self.init(host: link.host, port: link.port, tls: link.tls, room: "")
    }

    init(host: String, port: Int, tls: Bool, room: String, roomName: String = "", deviceID: String = "",
         scope: DeviceScope = .room) {
        self.host = host
        self.port = port
        self.tls = tls
        self.room = room
        self.roomName = roomName
        self.deviceID = deviceID
        self.scope = scope
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(host.trimmingCharacters(in: .whitespaces), forKey: "channel.host")
        d.set(port, forKey: "channel.port")
        d.set(tls, forKey: "channel.tls")
        d.set(room, forKey: "channel.room")
        d.set(roomName, forKey: "channel.roomName")
        d.set(deviceID, forKey: "channel.device")
        d.set(scope.rawValue, forKey: "channel.scope")
    }

    /// Every key `load` reads; 先体验 and the fixtures override them in the argument domain.
    static let keys = ["channel.host", "channel.port", "channel.tls", "channel.room", "channel.roomName",
                       "channel.device", "channel.scope"]
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

    /// Settings key: with ambient mode off, the phone plays 多多's replies aloud while the app is in
    /// front (default off). Ambient mode always plays them.
    static let speakRepliesKey = "audio.speakReplies"
    static var speakReplies: Bool { UserDefaults.standard.bool(forKey: speakRepliesKey) }

    /// Settings key: the screen stays on while the app is in front (default off), so the phone
    /// can stand out as a speaker.
    static let keepAwakeKey = "screen.keepAwake"
    static var keepAwake: Bool { UserDefaults.standard.bool(forKey: keepAwakeKey) }
}
