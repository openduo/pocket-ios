// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import Foundation
import PocketCore
import PocketOpus
import UIKit

/// What the ambient view and pill show (design §4.7). Published on change, never per frame.
struct AmbientSnapshot: Equatable {
    enum Phase: Equatable {
        case off
        case starting
        case listening
        case muted
        /// Another edge holds the room's seat.
        case seatTaken
        /// The room has no live capture master while on, or the mic was revoked.
        case deaf
        /// Audio session interrupted (call, Siri, alarm).
        case interrupted
        case failed(String)
    }

    var phase = Phase.off
    var speaking = false
    var speakingFiller = false
    var aec = false
    var route = ""
    var pressMuted = false
    var thermalWarning = false

    var isOn: Bool { phase != .off }
}

/// Native ambient edge (design §7): the edge socket, the audio engine and the `AmbientEdge` state
/// machine. All state lives on `queue`; audio callbacks hop onto it with O(1) work.
///
/// Lifecycle (decision Q3): started by the user in the foreground, continues in the background
/// and while locked through the `audio` background mode, ended by the user. Interruptions pause
/// it and resume when the system allows.
final class AmbientController: @unchecked Sendable {
    static let shared = AmbientController()

    /// Pause between edge-socket redials while on: the web edge's 1 s (`transport.js`).
    static let redialDelay: TimeInterval = 1

    private let queue = DispatchQueue(label: "pocket.ambient", qos: .userInitiated)
    private let socket = EdgeSocket()
    private var edge = AmbientEdge()
    private var decoder: OpusVoiceDecoder?
    /// Counters of the speech being played; logged on drain and when it ends.
    private var stats: PlaybackStats?
    private var settings = ChannelSettings.load()
    private var tuning = PocketTuning.load()

    private var on = false
    private var interrupted = false
    private var failure: String?
    private var dialing = false
    private var socketGeneration = 0

    private let snapLock = NSLock()
    private var snap = AmbientSnapshot()
    /// Called on the main queue after the snapshot changed (coalesced).
    var onChange: (() -> Void)?
    private var publishPending = false

    private init() {
        socket.onText = { [weak self] t in self?.queue.async { self?.text(t) } }
        socket.onBinary = { [weak self] d in self?.queue.async { self?.binary(d) } }
        socket.onClosed = { [weak self] why in self?.queue.async { self?.closed(why) } }
        VoiceIO.shared.onRebuildNeeded = { [weak self] why in self?.queue.async { self?.rebuildAudio(why) } }
        VoiceIO.shared.onRouteChanged = { [weak self] in self?.queue.async { self?.routeChanged() } }
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            self?.queue.async { self?.interruption(type, resume: opts?.contains(.shouldResume) ?? false) }
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.publish() }
        }
    }

    func snapshot() -> AmbientSnapshot {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap
    }

    // MARK: user actions

    func turnOn() {
        queue.async { [self] in
            guard !on else { return }
            settings = ChannelSettings.load()
            tuning = PocketTuning.load()
            on = true
            interrupted = false
            failure = nil
            edge = AmbientEdge(room: settings.room)
            AppLog.shared.log("ambient_on")
            startAudio()
            dial()
            publish()
        }
    }

    func turnOff() {
        queue.async { [self] in
            guard on else { return }
            on = false
            AppLog.shared.log("ambient_off")
            // The channel's mic switch is a room control that outlives this socket: do not leave
            // the room's mic off for the next edge (`on` = mic on).
            if edge.helloSent, edge.muted { socket.send(json: ["type": "mute", "on": true]) }
            stopAll()
            publish()
        }
    }

    func setMuted(_ m: Bool) {
        queue.async { [self] in
            perform(edge.setUserMute(m))
            publish()
        }
    }

    /// 别说了.
    func hush() { queue.async { [self] in perform(edge.hush()); publish() } }

    /// 在这台手机上听: take the seat from another edge.
    func takeover() { queue.async { [self] in perform(edge.takeover()); publish() } }

    /// Retry after deaf / failed.
    func reopen() {
        queue.async { [self] in
            guard on else { return }
            failure = nil
            interrupted = false
            stopAll()
            edge = AmbientEdge(room: settings.room)
            startAudio()
            dial()
            publish()
        }
    }

    /// A press (phone hold-to-talk or Passport) began or ended: mute the room for its length
    /// (decision Q12).
    func pressBegan() { queue.async { [self] in perform(edge.pressBegan()); publish() } }
    func pressEnded() { queue.async { [self] in perform(edge.pressEnded()); publish() } }

    // MARK: audio

    private func startAudio() {
        do {
            try VoiceIO.shared.startAmbient { [weak self] packet in
                // Engine thread → our queue; one append-sized hop per 20 ms packet.
                self?.queue.async { self?.uplink(packet) }
            }
            edge.aec = VoiceIO.shared.voiceProcessing
            decoder = try? OpusVoiceDecoder()
        } catch {
            if case VoiceIO.Failure.permissionDenied = error {
                failure = String(localized: "需要麦克风权限才能听")
            } else {
                failure = String(localized: "麦克风打不开：\(String(describing: error))")
            }
            AppLog.shared.log("ambient_audio_error", ["err": "\(error)"])
        }
    }

    private func stopAll() {
        VoiceIO.shared.stopAmbient()
        edge.captureStopped()
        perform(edge.socketClosed())
        socketGeneration += 1
        socket.close()
        decoder = nil
    }

    private func rebuildAudio(_ why: String) {
        guard on, !interrupted else { return }
        let aecBefore = edge.aec
        do {
            try VoiceIO.shared.rebuild()
            edge.aec = VoiceIO.shared.voiceProcessing
            if edge.aec != aecBefore {
                // `aec` changed with the route: say it again in a fresh hello.
                perform(edge.takeover())
            }
        } catch {
            failure = String(localized: "音频重启失败：\(String(describing: error))")
        }
        AppLog.shared.log("ambient_audio_rebuild", ["why": why, "aec": edge.aec])
        publish()
    }

    /// The engine recovered from a route change in place. If echo cancellation changed with the
    /// route, say so in a fresh hello (design §7.3).
    private func routeChanged() {
        guard on else { return }
        let aec = VoiceIO.shared.voiceProcessing
        if aec != edge.aec {
            edge.aec = aec
            perform(edge.takeover())
        }
        publish()
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, resume: Bool) {
        guard on else { return }
        switch type {
        case .began:
            interrupted = true
            AppLog.shared.log("ambient_interrupted")
            stopAll()
        case .ended:
            AppLog.shared.log("ambient_interruption_ended", ["resume": resume])
            guard interrupted, resume else { break }
            interrupted = false
            edge = AmbientEdge(room: settings.room)
            startAudio()
            dial()
        default:
            break
        }
        publish()
    }

    private func uplink(_ packet: Data) {
        guard on else { return }
        if !edge.capturing { perform(edge.packetEncoded()) }
        if edge.sendsAudio, socket.isOpen { socket.send(packet: packet) }
    }

    // MARK: socket

    private func dial() {
        guard on, !dialing, !interrupted, failure == nil else { return }
        dialing = true
        socketGeneration += 1
        let gen = socketGeneration
        let s = settings, timeout = tuning.connectTimeout
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var err: String?
            do { try socket.open(room: s, timeout: timeout) } catch { err = "\(error)" }
            queue.async { [self] in
                dialing = false
                guard gen == socketGeneration, on else {
                    if err == nil, !on { socket.close() }
                    return
                }
                AppLog.shared.log("edge_dial", ["ok": err == nil, "err": err ?? "", "app": AppPhase.value])
                if err == nil {
                    edge.socketOpened()
                } else {
                    queue.asyncAfter(deadline: .now() + Self.redialDelay) { [self] in dial() }
                }
                publish()
            }
        }
    }

    private func closed(_ why: String) {
        AppLog.shared.log("edge_closed", ["reason": why, "app": AppPhase.value])
        perform(edge.socketClosed())
        publish()
        guard on else { return }
        // 1008: the channel refused the request (room, origin); redialling unchanged cannot help.
        if why.contains("PolicyViolation") {
            failure = String(localized: "频道拒绝了这个房间")
            publish()
            return
        }
        queue.asyncAfter(deadline: .now() + Self.redialDelay) { [self] in dial() }
    }

    private func text(_ t: String) {
        guard on, let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        // Only audio-plane frames matter here; the display socket handles the conversation.
        guard type == "meta" || type == "audio_params" || type == "speech" || type == "stop_audio" else { return }
        let before = (edge.role, edge.roomState)
        if type == "speech" { endStats("replaced") }
        perform(edge.frame(obj))
        if type == "speech", let id = edge.current {
            stats = PlaybackStats(speechID: id, gen: edge.gen)
            AppLog.shared.log("speech_begin", ["speech_id": id])
        }
        if type == "meta" {
            AppLog.shared.log("edge_meta", ["conn": obj["conn"] as? String ?? "", "role": obj["role"] as? String ?? "",
                                            "state": obj["state"] as? String ?? ""])
        }
        if type != "meta" || before != (edge.role, edge.roomState) { publish() }
    }

    private func binary(_ d: Data) {
        guard on else { return }
        perform(edge.binary(d))
    }

    private func perform(_ actions: [AmbientEdge.Action]) {
        for a in actions {
            switch a {
            case .send(let f):
                socket.send(json: f)
                if let t = f["type"] as? String, t != "played" { AppLog.shared.log("edge_send", ["type": t]) }
            case .play(let packet, let gen):
                stats?.frameReceived()
                let samples: [Int16]
                do {
                    guard let decoder else { throw PlaybackFailure.noDecoder }
                    samples = try decoder.decode(packet)
                    if samples.isEmpty { throw PlaybackFailure.emptyDecode }
                } catch {
                    if stats?.decodeFailed("\(error)") == true {
                        AppLog.shared.log("speech_decode_error", ["speech_id": stats?.speechID ?? "", "err": "\(error)",
                                                                  "bytes": packet.count])
                    }
                    continue
                }
                let ms = Double(samples.count) * 1000 / Double(PocketConstants.sampleRate)
                let wasSpeaking = edge.speaking
                if VoiceIO.shared.schedule(samples, done: { [weak self] in
                    self?.queue.async { self?.blockPlayed(gen: gen, ms: ms) }
                }) {
                    edge.scheduled(gen: gen)
                    stats?.scheduled(ms: ms)
                } else if stats?.scheduleFailed() == true {
                    AppLog.shared.log("speech_schedule_error", ["speech_id": stats?.speechID ?? "",
                                                                "engine": VoiceIO.shared.running])
                }
                if !wasSpeaking, edge.speaking { publish() }
            case .clearPlayback:
                // Emitted only when a speech stops (stop_audio, hush, socket closed, ambient off).
                endStats("stopped")
                VoiceIO.shared.clearPlayback()
            case .resetDecoder:
                decoder = try? OpusVoiceDecoder()
            case .fatal(let why):
                AppLog.shared.log("ambient_fatal", ["why": why])
                failure = why
                stopAll()
            case .warn(let why):
                AppLog.shared.log("ambient_warn", ["why": why])
            }
        }
    }

    private func blockPlayed(gen: Int, ms: Double) {
        let was = edge.speaking
        stats?.played(gen: gen, ms: ms)
        perform(edge.played(gen: gen, ms: ms))
        if was != edge.speaking {
            if !edge.speaking, let stats { AppLog.shared.log("speech_stats", stats.fields(why: "drained")) }
            publish()
        }
    }

    /// Logs the current speech's counters once and forgets them.
    private func endStats(_ why: String) {
        guard let s = stats else { return }
        stats = nil
        AppLog.shared.log("speech_stats", s.fields(why: why))
    }

    private enum PlaybackFailure: Error, CustomStringConvertible {
        case noDecoder, emptyDecode
        var description: String {
            switch self {
            case .noDecoder: "no decoder"
            case .emptyDecode: "decoded 0 samples"
            }
        }
    }

    // MARK: publish

    private func publish() {
        var s = AmbientSnapshot()
        if !on {
            s.phase = .off
        } else if let failure {
            s.phase = .failed(failure)
        } else if interrupted {
            s.phase = .interrupted
        } else if edge.userMuted {
            s.phase = .muted
        } else if !edge.helloSent {
            s.phase = .starting
        } else if edge.role == .peer {
            s.phase = .seatTaken
        } else if edge.roomState == "unowned" {
            s.phase = .deaf
        } else {
            s.phase = .listening
        }
        s.speaking = edge.speaking
        s.speakingFiller = edge.speakingFiller
        s.aec = edge.aec
        s.route = on ? VoiceIO.routeName : ""
        s.pressMuted = edge.pressCount > 0
        // `.serious` is the level at which Apple asks apps to reduce work.
        s.thermalWarning = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        snapLock.lock()
        let changed = snap != s
        snap = s
        snapLock.unlock()
        guard changed else { return }
        // Background rule: no UI work while not active; the view reads the snapshot on return.
        guard AppPhase.isActive, !publishPending else { return }
        publishPending = true
        DispatchQueue.main.async { [self] in
            queue.async { self.publishPending = false }
            onChange?()
        }
    }
}
