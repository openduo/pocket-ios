// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// The native ambient edge's protocol state (design §7), the same rules as the channel's web edge
/// (`capture.js`, `transport.js`, `audio-link.js`, `opus.js::createPlayClock`). Pure: inputs in,
/// actions out; the controller performs the actions (socket writes, decoding, playback).
///
/// Uplink (capture → seat):
/// - `hello{edge:"client", aec}` leaves only once an encoded packet exists and the socket has
///   told us its `conn` (a seat without audio makes the room deaf); it is re-sent on every new
///   `meta{conn}` while capturing (reconnect reclaims the seat).
/// - `meta{role:"peer"}`: another edge holds the seat; stop sending audio until the user takes it
///   over (a fresh `hello`).
/// - `mute{on}` is the room's capture switch, `on` = mic on. The user's 静音 sends `mute{on:false}`
///   and stops sending bytes (bytes do not leave the phone). A press (phone hold-to-talk or
///   Passport) switches the room mic off for its length so the same
///   speech does not enter the brain twice (design Q12); audio keeps flowing during a press
///   because the channel drops it while muted and the seat lease (`seat_starve_ms`) would expire
///   during a long press otherwise.
///
/// Downlink (playback):
/// 1. Binary frames belong to the latest `speech{speech_id}`; one before any `speech` is dropped.
/// 2. `played{speech_id, ms}` is a cumulative watermark from playback completion, reported when
///    it moved by `playedReportMs` and once when the queue drains.
/// 3. `stop_audio` stops an answer (`c-…`) at once and never reports it again; a filler (`s…`)
///    plays out. A local 别说了 stops everything and sends `hush`.
/// 4. Generations: `speech` and `stop_audio` start a new generation; completion callbacks of an
///    older generation are ignored, so one speech's tail is never credited to the next.
public struct AmbientEdge: Equatable {
    /// Cadence of intermediate `played` reports, the web edge's `PLAYED_REPORT_MS`.
    public static let playedReportMs = 250.0
    /// Wire sample rate (docs/ble-protocol.md §1). `audio_params.rate` is a notification, not a
    /// negotiation.
    public static let rate = 16_000
    /// Cerebellum-allocated filler speech ids (`CERE_SPEECH_PREFIX`).
    public static let fillerPrefix = "s"

    public enum Role: String, Equatable { case master, peer }

    public enum Action: Equatable {
        /// One JSON text frame for the edge socket.
        case send([String: AnyHashable])
        /// Decode this packet and schedule it under generation `gen`.
        case play(Data, gen: Int)
        /// Stop and drop everything scheduled.
        case clearPlayback
        case resetDecoder
        /// Protocol mismatch the controller must surface and stop on.
        case fatal(String)
        case warn(String)
    }

    // Connection.
    public private(set) var conn: String?
    public private(set) var role: Role?
    public private(set) var roomState: String?
    public private(set) var helloSent = false
    /// An encoded packet exists (capture is live).
    public private(set) var capturing = false
    public var aec = false
    public private(set) var userMuted = false
    public private(set) var pressCount = 0
    public var room = ""

    // Playback.
    public private(set) var current: String?
    public private(set) var gen = 0
    public private(set) var pending = 0
    public private(set) var speaking = false
    private var clockID: String?
    private var playedMs = 0.0
    private var lastReported = -1.0

    public init(room: String = "") { self.room = room }

    /// Whether a captured packet goes up the socket now.
    public var sendsAudio: Bool { helloSent && role != .peer && !userMuted }
    public var muted: Bool { userMuted || pressCount > 0 }
    public var speakingFiller: Bool { speaking && (current?.hasPrefix(Self.fillerPrefix) ?? false) }

    // MARK: socket

    /// A new socket opened: nothing about the old connection carries over.
    public mutating func socketOpened() {
        conn = nil
        role = nil
        roomState = nil
        helloSent = false
    }

    /// The socket closed: stop playback (no `played` can reach the channel anyway).
    public mutating func socketClosed() -> [Action] {
        conn = nil
        role = nil
        roomState = nil
        helloSent = false
        return stopSpeech(nil)
    }

    /// Capture stopped (ambient off, interruption): the next start must hello again.
    public mutating func captureStopped() {
        capturing = false
        helloSent = false
    }

    // MARK: uplink

    /// One encoded packet exists. Returns the hello when this is the moment to send it.
    public mutating func packetEncoded() -> [Action] {
        if capturing { return [] }
        capturing = true
        return hello()
    }

    /// Takeover from a peer: an explicit user gesture re-sends the full hello.
    public mutating func takeover() -> [Action] {
        guard capturing, conn != nil else { return [] }
        helloSent = false
        return hello()
    }

    private mutating func hello() -> [Action] {
        guard capturing, let conn, !helloSent else { return [] }
        helloSent = true
        // The channel's mic switch is a room control that outlives a connection; state ours again.
        return [.send(["type": "hello", "room": room, "conn": conn, "edge": "client", "aec": aec]), micFrame()]
    }

    /// `mute{on}` is the channel's capture master switch: `on` means the room's mic is ON
    /// (`EdgeMuteFrame`, state.ts sets `micOn = on`). Muting sends `on:false`.
    public func micFrame() -> Action { .send(["type": "mute", "on": !muted]) }

    public mutating func setUserMute(_ on: Bool) -> [Action] {
        let before = muted
        userMuted = on
        return before != muted && helloSent ? [micFrame()] : []
    }

    public mutating func pressBegan() -> [Action] {
        let before = muted
        pressCount += 1
        return before != muted && helloSent ? [micFrame()] : []
    }

    public mutating func pressEnded() -> [Action] {
        guard pressCount > 0 else { return [] }
        let before = muted
        pressCount -= 1
        return before != muted && helloSent ? [micFrame()] : []
    }

    /// 别说了: stop everything locally, fillers included, then ask the channel to stop.
    public mutating func hush() -> [Action] {
        stopSpeech(nil) + [.send(["type": "hush"])]
    }

    // MARK: downlink

    /// One text frame (already decoded). Returns the actions; frames outside the audio plane
    /// return nothing.
    public mutating func frame(_ f: [String: Any]) -> [Action] {
        switch f["type"] as? String {
        case "meta":
            var out: [Action] = []
            if let c = f["conn"] as? String {
                conn = c
                helloSent = false
                out += hello()
            }
            if let r = f["role"] as? String, let role = Role(rawValue: r) { self.role = role }
            if let s = f["state"] as? String {
                roomState = s
                if s == "unowned" { role = nil }
            }
            return out
        case "audio_params":
            if let r = f["rate"] as? Int, r != Self.rate {
                return [.fatal("audio_params.rate=\(r), expected \(Self.rate) (the rate is not negotiated)")]
            }
            return []
        case "speech":
            guard let id = f["speech_id"] as? String else { return [] }
            gen += 1
            pending = 0
            current = id
            clockID = id
            playedMs = 0
            lastReported = -1
            return [.resetDecoder]
        case "stop_audio":
            if let cur = current, cur.hasPrefix(Self.fillerPrefix) { return [] }
            return stopSpeech(f["speech_id"] as? String)
        default:
            return []
        }
    }

    /// One binary frame (one Opus packet).
    public mutating func binary(_ packet: Data) -> [Action] {
        guard current != nil else { return [.warn("binary frame before any speech declaration (dropped)")] }
        return [.play(packet, gen: gen)]
    }

    /// The controller scheduled one decoded block of `gen`.
    public mutating func scheduled(gen g: Int) {
        guard g == gen, current != nil else { return }
        pending += 1
        speaking = true
    }

    /// One scheduled block of `gen` finished playing (`ms` of audio).
    public mutating func played(gen g: Int, ms: Double) -> [Action] {
        guard g == gen, pending > 0 else { return [] }
        pending -= 1
        var out: [Action] = []
        if let id = clockID {
            playedMs += ms
            if lastReported < 0 || playedMs - lastReported >= Self.playedReportMs {
                lastReported = playedMs
                out.append(.send(["type": "played", "speech_id": id, "ms": Int(playedMs.rounded())]))
            }
        }
        if pending == 0 {
            if let id = clockID, playedMs != lastReported {
                lastReported = playedMs
                out.append(.send(["type": "played", "speech_id": id, "ms": Int(playedMs.rounded())]))
            }
            speaking = false
        }
        return out
    }

    private mutating func stopSpeech(_ id: String?) -> [Action] {
        if let id, let cur = current, id != cur { return [] }
        gen += 1
        pending = 0
        current = nil
        if id == nil || id == clockID { clockID = nil }
        speaking = false
        return [.clearPlayback, .resetDecoder]
    }
}
