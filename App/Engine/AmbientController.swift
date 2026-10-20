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
        /// Another edge holds the room's seat.
        case seatTaken
        /// The room has no live capture master while on, or the mic was revoked.
        case deaf
        /// Audio session interrupted (call, Siri, alarm).
        case interrupted
        case failed(String)
    }

    var phase = Phase.off
    /// 静音: this ambient session plays nothing on the phone; it still listens.
    var silent = false
    var speaking = false
    var speakingFiller = false
    var aec = false
    var route = ""
    var pressMuted = false
    var thermalWarning = false
    /// The audio session is interrupted, whatever `phase` shows (a failure outranks it there).
    var interrupted = false

    var isOn: Bool { phase != .off }
}

/// Native ambient edge (design §7): the room's `/live` socket, the audio engine and the
/// `AmbientEdge` state machine. All state lives on `queue`; audio callbacks hop onto it with O(1)
/// work.
///
/// The phone is a mouth whenever its connection was opened with `audio=1`: replies play here with
/// ambient off too (the room is then in message mode, and nothing is reported back). The switch
/// is on while ambient mode runs, and otherwise the 播放语音回复 setting while the app is in front,
/// so no reply plays from a pocket. A change is a new connection from the cursor. A read aloud
/// (`POST /api/speech`) plays here as well, outside the room's speech.
///
/// The app holds one `/live` connection, owned here. Its conversation frames go to
/// `PocketEngine`, its audio plane to the edge. Ambient on says `hello` on the open connection;
/// ambient off closes it, and `PocketEngine` opens a new one without `hello` (a connection cannot
/// leave the seat). `PocketEngine` decides when the connection is wanted and reopens it.
///
/// Lifecycle (decision Q3): started by the user in the foreground, continues in the background
/// and while locked through the `audio` background mode, ended by the user. Interruptions pause
/// it and resume when the system allows.
final class AmbientController: @unchecked Sendable {
    static let shared = AmbientController()

    private let queue = DispatchQueue(label: "pocket.ambient", qos: .userInitiated)
    let live = LiveSocket()
    /// `conn` of the open connection (its first `meta`), so ambient mode turned on later can say
    /// `hello` on it.
    private var liveConn: String?
    /// The `audio` switch the open connection was opened with.
    private var liveAudio: Bool?
    /// The read aloud in progress: its request, decoder, framing and blocks not yet played.
    private var read: StreamRequest?
    private var readDecoder: OpusVoiceDecoder?
    private var readStream = PacketStream()
    private var readQueued = 0
    private var readBodyEnded = false
    private var readStarted = false
    /// Called on the main queue when a read aloud did not play in full.
    var onReadFailure: ((ReadAloudFailure) -> Void)?
    private var edge = AmbientEdge()
    private var decoder: OpusVoiceDecoder?
    /// Counters of the speech being played; logged on drain and when it ends.
    private var stats: PlaybackStats?
    private var settings = ChannelSettings.load()
    private var tuning = PocketTuning.load()

    private var on = false
    /// The surface last reported on the open `/live` connection; nil after it is replaced.
    private var surfaceSent: Surface?
    /// 静音 for this ambient session; a new session starts audible.
    private var silent = false
    private var interrupted = false
    private var failure: String?

    private let snapLock = NSLock()
    private var snap = AmbientSnapshot()
    /// Called on the main queue after the snapshot changed (coalesced).
    var onChange: (() -> Void)?
    private var publishPending = false

    private init() {
        live.onText = { [weak self] t in
            // Parsed once here; one frame per conversation event, never per audio packet.
            guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return }
            self?.queue.async { self?.text(obj) }
            PocketEngine.shared.liveFrame(obj)
        }
        live.onBinary = { [weak self] d in self?.queue.async { self?.binary(d) } }
        live.onClosed = { [weak self] why in
            self?.queue.async { self?.closed(why) }
            PocketEngine.shared.liveClosed(why)
        }
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
            setSilentOnQueue(false)
            interrupted = false
            failure = nil
            // The ambient engine replaces the playback-only one: a read in progress ends here.
            stopRead()
            // Ambient mode always asks `audio=1`: replace a connection opened without it before
            // the new edge says `hello` on it. Likewise one opened before an arrival the room has
            // not heard of, so the new connection carries it.
            if liveAudio != nil, liveAudio != wantsAudio || ArrivalMonitor.shared.report() != nil {
                liveReplaced()
                live.close()
            }
            newEdge()
            AppLog.shared.log("ambient_on")
            startAudio()
            PocketEngine.shared.ensureLive("ambient_on")
            publish()
        }
    }

    /// A fresh edge for a new capture session, told the open connection's `conn`: its `hello`
    /// goes on that connection with the first encoded packet.
    private func newEdge() {
        edge = AmbientEdge(room: settings.room)
        if let liveConn, live.isOpen { perform(edge.frame(["type": "meta", "conn": liveConn])) }
    }

    func turnOff() {
        queue.async { [self] in
            guard on else { return }
            on = false
            // Interruptions are tracked while ambient runs only; the reopened connection asks
            // for the setting again.
            interrupted = false
            AppLog.shared.log("ambient_off")
            // The channel's mic switch is a room control that outlives this socket: do not leave
            // the room's mic off for the next edge (`on` = mic on).
            if edge.helloSent, edge.muted { live.send(json: ["type": "mute", "on": true]) }
            stopRead()
            stopAll()
            setSilentOnQueue(false)
            publish()
        }
    }

    /// 静音: the phone stops playing the room's speech for this session and keeps listening. New
    /// speech is not played and is reported played at once; blocks already queued finish at zero
    /// volume.
    func setSilent(_ s: Bool) {
        queue.async { [self] in
            setSilentOnQueue(s)
            publish()
        }
    }

    private func setSilentOnQueue(_ s: Bool) {
        guard silent != s else { return }
        silent = s
        VoiceIO.shared.setOutputMuted(s)
        AppLog.shared.log("ambient_silent", ["on": s])
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
            newEdge()
            startAudio()
            PocketEngine.shared.ensureLive("ambient_reopen")
            publish()
        }
    }

    /// A press (phone hold-to-talk or Passport) began or ended: mute the room for its length
    /// (decision Q12). While ambient mode plays answers, a press also stops playback and nothing
    /// plays until it ends (`AmbientEdge.pressBegan`).
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

    /// Stops capture and closes the connection: a seated connection cannot leave the seat.
    /// `PocketEngine` opens a new one without `hello`.
    private func stopAll() {
        stopRead()
        VoiceIO.shared.stopAmbient()
        edge.captureStopped()
        liveReplaced()
        live.close()
        decoder = nil
        PocketEngine.shared.ensureLive("ambient_stop")
    }

    /// The held connection is gone (closed, replaced): nothing of it carries over.
    private func liveReplaced() {
        liveConn = nil
        liveAudio = nil
        surfaceSent = nil
        perform(edge.socketClosed())
    }

    // MARK: the /live connection (called by PocketEngine, off the queues)

    /// Opens the room's `/live` connection, replacing the held one. Blocking.
    func openLive(_ s: ChannelSettings, since: Int?, timeout: TimeInterval) throws {
        // The old connection's state ends before the new one's first frame can arrive.
        let (audio, ambient) = queue.sync {
            liveReplaced()
            publish()
            liveAudio = wantsAudio
            return (wantsAudio, on)
        }
        // Ambient mode's connection carries a pending arrival; the channel gives it to the
        // session's first turn. The upgrade succeeding counts as reported.
        let place = ambient ? ArrivalMonitor.shared.report() : nil
        try live.open(path: ChannelPaths.live(room: s.room, since: since, audio: audio),
                      headers: place?.headers ?? [:], timeout: timeout)
        ArrivalMonitor.shared.settle(place, accepted: true)
        // A new connection starts unreported, whatever reached the old one meanwhile.
        queue.async { [self] in
            surfaceSent = nil
            reportSurfaceOnQueue()
        }
    }

    /// Sends the app's surface on the open connection when it differs from the last one sent.
    func reportSurface() {
        queue.async { [self] in reportSurfaceOnQueue() }
    }

    private func reportSurfaceOnQueue() {
        guard live.isOpen else { return }
        let s = PocketSurface.current()
        guard s != surfaceSent else { return }
        surfaceSent = s
        live.send(json: s.frame)
        AppLog.shared.log("surface_send", ["display": s.display.rawValue, "spoken": s.spoken])
    }

    /// The `audio` switch a connection opened now asks for: always while ambient mode runs (it is
    /// a voice in the room; the user mutes it there), else the setting while the app is in front.
    /// Not while the audio session is interrupted: the phone cannot play during a call, so it
    /// must not count as a mouth.
    private var wantsAudio: Bool {
        !interrupted && (on || (AudioPreferences.speakReplies && AppPhase.value != "background"))
    }

    /// Whether the open connection's `audio` switch is still the one wanted. A connection that is
    /// not is replaced by `PocketEngine` from the cursor.
    var liveAudioCurrent: Bool { queue.sync { liveAudio == wantsAudio } }

    /// The setting or the foreground changed. A connection opened with the other switch is
    /// replaced (`PocketEngine` redials it while wanted, else it is closed). In the background
    /// with ambient off nothing plays: a read stops too.
    func audioWantChanged(_ reason: String) {
        queue.async { [self] in
            if !on, AppPhase.value == "background" { stopRead() }
            reportSurfaceOnQueue()
            guard liveAudio != nil, liveAudio != wantsAudio else { return }
            AppLog.shared.log("live_audio_change", ["reason": reason, "audio": wantsAudio])
            PocketEngine.shared.liveAudioChanged(reason)
        }
    }

    /// Closes the connection (settings changed).
    func closeLive() {
        queue.sync { liveReplaced(); publish() }
        live.close()
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
            // The connection opened during the interruption asked `audio=0`: replace it before
            // the new edge says `hello` on it.
            if liveAudio != nil, liveAudio != wantsAudio {
                liveReplaced()
                live.close()
            }
            newEdge()
            startAudio()
            PocketEngine.shared.ensureLive("ambient_resume")
        default:
            break
        }
        publish()
    }

    private func uplink(_ packet: Data) {
        guard on else { return }
        if !edge.capturing { perform(edge.packetEncoded()) }
        if edge.sendsAudio, live.isOpen { live.send(packet: packet) }
    }

    // MARK: socket

    /// The connection closed from the far side. `PocketEngine` redials while it wants it.
    private func closed(_ why: String) {
        AppLog.shared.log("live_closed", ["reason": why, "app": AppPhase.value])
        liveReplaced()
        publish()
        guard on else { return }
        // 1008: the channel refused the request (room, origin); redialling unchanged cannot help.
        if why.contains("PolicyViolation") {
            failure = String(localized: "频道拒绝了这个房间")
            publish()
        }
    }

    private func text(_ obj: [String: Any]) {
        let type = obj["type"] as? String
        if type == "meta", let c = obj["conn"] as? String { liveConn = c }
        // Only audio-plane frames matter here; `PocketEngine` handles the conversation. They
        // matter with ambient off too: an audio-on connection is a mouth in message mode.
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
        perform(edge.binary(d))
    }

    // MARK: read aloud

    /// Reads `text` aloud: `POST /api/speech`, played here as it streams in. It stops the reply
    /// that plays (with ambient on, reported `interrupted`); a press or a new `speech` stops it.
    func readAloud(_ text: String) {
        queue.async { [self] in
            settings = ChannelSettings.load()
            tuning = PocketTuning.load()
            perform(edge.readBegan())
            let request = StreamRequest { [weak self] owner, data in self?.queue.async { self?.readData(owner, data) } }
            read = request
            readDecoder = try? OpusVoiceDecoder()
            readStream = PacketStream()
            readQueued = 0
            readBodyEnded = false
            readStarted = false
            AppLog.shared.log("read_aloud", ["chars": text.count])
            let s = settings, upTimeout = tuning.connectTimeout
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let outcome: Result<(status: Int, body: Data), Error> = Result {
                    try Tailnet.shared.stream(request, method: "POST", path: ChannelPaths.speech(room: s.room),
                                              headers: ["Content-Type": "application/json"],
                                              body: ChannelPaths.speechBody(text: text), upTimeout: upTimeout)
                }
                queue.async { [self] in readFinished(request, outcome) }
            }
            publish()
        }
    }

    private func readData(_ request: StreamRequest, _ data: Data) {
        // Chunks of a stopped or replaced read are dropped.
        guard read === request else { return }
        for packet in readStream.push(data) {
            guard let samples = try? readDecoder?.decode(packet), !samples.isEmpty else { continue }
            readStarted = true
            let request = read
            if VoiceIO.shared.schedule(samples, done: { [weak self] in
                self?.queue.async { self?.readBlockPlayed(request) }
            }) {
                readQueued += 1
            }
        }
    }

    private func readBlockPlayed(_ request: StreamRequest?) {
        guard let request, read === request, readQueued > 0 else { return }
        readQueued -= 1
        if readBodyEnded, readQueued == 0 { endRead(nil) }
    }

    private func readFinished(_ request: StreamRequest, _ outcome: Result<(status: Int, body: Data), Error>) {
        // A read that was stopped or replaced ends without a word.
        guard read === request else { return }
        switch outcome {
        case .failure:
            endRead(readStarted ? .cut : .notConnected)
        case .success(let r) where r.status != 200:
            let error = ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["error"] as? String ?? ""
            endRead(ReadAloudFailure.of(status: r.status, error: error))
        case .success:
            readBodyEnded = true
            if readStream.partial > 0 { return endRead(.cut) }
            if readQueued == 0 { endRead(nil) }
        }
    }

    /// The read ended: played out, or failed (its audio already played stays played).
    private func endRead(_ failure: ReadAloudFailure?) {
        read = nil
        readDecoder = nil
        edge.readEnded()
        AppLog.shared.log("read_aloud_end", ["failure": failure.map { "\($0)" } ?? ""])
        if let failure { DispatchQueue.main.async { self.onReadFailure?(failure) } }
        publish()
    }

    /// Stops a read in progress (ambient turned on or off, the app left the front).
    private func stopRead() {
        guard edge.reading else { return }
        perform(edge.stopReading())
    }

    private func perform(_ actions: [AmbientEdge.Action]) {
        for a in actions {
            switch a {
            case .send(let f):
                live.send(json: f)
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
                if silent {
                    // 静音: the reply is not played; it counts as played at once.
                    perform(edge.skipped(gen: gen, ms: ms))
                    continue
                }
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
            case .stopRead:
                read?.cancel()
                read = nil
                readDecoder = nil
                AppLog.shared.log("read_aloud_stopped")
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
        } else if !edge.helloSent {
            s.phase = .starting
        } else if edge.role == .peer {
            s.phase = .seatTaken
        } else if edge.roomState == "unowned" {
            s.phase = .deaf
        } else {
            s.phase = .listening
        }
        s.silent = on && silent
        s.speaking = edge.speaking
        s.speakingFiller = edge.speakingFiller
        s.aec = edge.aec
        s.route = on ? VoiceIO.routeName : ""
        s.pressMuted = edge.pressCount > 0
        s.interrupted = interrupted
        // `.serious` is the level at which Apple asks apps to reduce work.
        s.thermalWarning = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        snapLock.lock()
        let changed = snap != s
        snap = s
        snapLock.unlock()
        guard changed else { return }
        reportSurfaceOnQueue()
        // Background rule: no UI work while not active; the view reads the snapshot on return.
        guard AppPhase.isActive, !publishPending else { return }
        publishPending = true
        DispatchQueue.main.async { [self] in
            queue.async { self.publishPending = false }
            onChange?()
        }
    }
}
