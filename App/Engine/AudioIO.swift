// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import Foundation
import PocketCore
import PocketOpus

/// The phone's one audio engine (design §7.3). Capture is converted to 16 kHz mono Int16
/// (docs/ble-protocol.md §1) and handed to the consumers (hold-to-talk voice note, ambient
/// uplink), each of which owns its Opus encoder. Ambient playback runs through an `AVAudioPlayerNode` on the same engine so
/// the voice-processing unit has the played signal as its echo reference.
///
/// Per tap buffer the work is one conversion, one O(n) RMS and the consumers' encode + append.
/// Nothing here touches UI; the level meter is a value the UI samples while visible.
final class VoiceIO: @unchecked Sendable {
    static let shared = VoiceIO()

    enum Failure: Error, CustomStringConvertible {
        case permissionDenied, converter, opus(String), engine(String)
        var description: String {
            switch self {
            case .permissionDenied: "microphone permission denied"
            case .converter: "audio converter unavailable"
            case .opus(let s): "opus: \(s)"
            case .engine(let s): "engine: \(s)"
            }
        }
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PocketConstants.sampleRate),
                                       channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: Double(PocketConstants.sampleRate), channels: 1)!

    // Consumers (guarded by `lock`).
    private var noteEncoder: OpusVoiceEncoder?
    private var notePackets: [Data] = []
    private var ambientEncoder: OpusVoiceEncoder?
    private var ambientSink: ((Data) -> Void)?

    /// Whether the running engine has voice processing (echo cancellation) on: the `aec` value of
    /// `hello`.
    private(set) var voiceProcessing = false
    private(set) var ambientMode = false
    /// Called after a media services reset; the owner rebuilds everything.
    var onRebuildNeeded: ((String) -> Void)?
    /// Called after the engine recovered from a configuration change (route change): voice
    /// processing may differ, so the owner re-reads `voiceProcessing`.
    var onRouteChanged: (() -> Void)?
    /// Serialises engine start/stop and configuration-change handling. Hold-to-talk starts the
    /// engine here, off the main thread, so the UI answers the touch while CoreAudio starts.
    private let configQueue = DispatchQueue(label: "pocket.audio.config")

    private var levelBits: UInt32 = 0 // Float bit pattern, guarded by `lock`
    /// Mic level 0…1 with the web edge's attack/decay (`capture.js`). Sampled by the UI.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return Float(bitPattern: levelBits)
    }

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            AppLog.shared.log("audio_media_reset")
            self?.onRebuildNeeded?("media_reset")
        }
    }

    var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return engine?.isRunning ?? false
    }

    static func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    static var permission: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }

    /// A short description of the output route ("扬声器", "AirPods") for the ambient pill.
    static var routeName: String {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        switch out?.portType {
        case .builtInSpeaker: return String(localized: "扬声器")
        case .builtInReceiver: return String(localized: "听筒")
        case .none: return "—"
        default: return out?.portName ?? "—"
        }
    }

    // MARK: engine

    /// Category options for hold-to-talk. The session is active only while a
    /// note records; other apps' audio mixes and is ducked for that time (`.duckOthers` implies
    /// mixing), and deactivation at the end lifts the ducking. AirPods stay in A2DP unless the
    /// user chose their microphone: without `.allowBluetoothHFP` the input is the phone's
    /// microphone and the output keeps the A2DP route.
    private static func noteOptions(bluetoothMic: Bool) -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers]
        if bluetoothMic { o.insert(.allowBluetoothHFP) }
        return o
    }

    /// A Bluetooth output (AirPods and other headsets) is on the current route.
    static var bluetoothOutput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    /// The note should record from a Bluetooth headset: the user chose its microphone and one
    /// is connected.
    private static var noteUsesBluetoothMic: Bool { AudioPreferences.headsetMic && bluetoothOutput }

    private func configureSession(ambient: Bool, bluetoothMic: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            if ambient {
                // Ambient: voice chat (echo cancellation), AirPods in HFP, not mixable.
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: Self.noteOptions(bluetoothMic: bluetoothMic))
            }
            // iOS mutes haptics while the session records unless allowed: the hold-to-talk
            // start, send and cancel haptics all fire while the mic runs.
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            HoldTiming.shared.mark("session_category")
            try session.setActive(true)
            HoldTiming.shared.mark("session_active")
        } catch {
            throw Failure.engine("session: \(error.localizedDescription)")
        }
    }

    /// Builds the graph (input tap, player) without starting it.
    private func buildEngine(ambient: Bool) throws {
        let e = AVAudioEngine()
        var vp = false
        if ambient {
            do {
                try e.inputNode.setVoiceProcessingEnabled(true)
                vp = e.inputNode.isVoiceProcessingEnabled && !e.inputNode.isVoiceProcessingBypassed
                // Voice processing otherwise ducks other apps' audio hard.
                e.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                AppLog.shared.log("audio_vp_error", ["err": error.localizedDescription])
            }
        }
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: playFormat)
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let conv = AVAudioConverter(from: format, to: target) else { throw Failure.converter }
        conv.downmix = true
        // The tap's buffer size is a request; iOS delivers 100 ms blocks regardless
        // (docs/constants.md, hold-to-talk tap size).
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in self?.consume(buf, when) }
        HoldTiming.shared.mark("engine_built")
        e.prepare()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged(_:)),
                                               name: .AVAudioEngineConfigurationChange, object: e)
        lock.lock()
        engine = e
        player = p
        converter = conv
        voiceProcessing = vp
        ambientMode = ambient
        lock.unlock()
    }

    /// Starts the built engine. On failure the engine is discarded.
    private func startBuilt() throws {
        lock.lock()
        let e = engine, p = player, ambient = ambientMode, vp = voiceProcessing
        lock.unlock()
        guard let e else { throw Failure.engine("no engine") }
        do {
            try e.start()
            HoldTiming.shared.mark("engine_running")
        } catch {
            stopEngine()
            throw Failure.engine(error.localizedDescription)
        }
        p?.play()
        let format = e.inputNode.outputFormat(forBus: 0)
        AppLog.shared.log("audio_start", ["ambient": ambient, "vp": vp, "in_rate": format.sampleRate,
                                          "in_ch": format.channelCount, "route": Self.routeName,
                                          "in_route": Self.inputName])
    }

    /// Starts (or restarts into) the needed mode. Ambient wants voice processing and playback;
    /// a voice note alone records plainly.
    private func ensureEngine(ambient: Bool) throws {
        lock.lock()
        let current = engine
        let running = current?.isRunning == true
        let sameMode = current != nil && ambientMode == ambient
        lock.unlock()
        if running, sameMode {
            HoldTiming.shared.note("engine", "running")
            return
        }
        let bluetoothMic = !ambient && Self.noteUsesBluetoothMic
        HoldTiming.shared.note("engine", "cold")
        stopEngine()
        try configureSession(ambient: ambient, bluetoothMic: bluetoothMic)
        try buildEngine(ambient: ambient)
        try startBuilt()
    }

    /// A short description of the input route ("iPhone 麦克风", "AirPods"), for the log.
    static var inputName: String {
        let i = AVAudioSession.sharedInstance().currentRoute.inputs.first
        return i.map { "\($0.portType.rawValue):\($0.portName)" } ?? "-"
    }

    /// A configuration change (route, hardware format; also one right after a voice-processing
    /// engine starts) stops the engine but keeps its graph. Recover in place: re-tap if the input
    /// format changed, restart if stopped. Rebuilding the engine here would trigger another change
    /// and loop.
    ///
    /// A stopped engine also gets its player reconnected before the restart: after the
    /// voice-processing change the player stays `isPlaying` but never consumes a scheduled buffer
    /// (measured on the iPhone 17 Pro Max). Reconnecting player → mixer fixes it.
    @objc private func configChanged(_ n: Notification) {
        configQueue.async { [self] in
            lock.lock()
            let e = engine, p = player, conv = converter
            lock.unlock()
            guard let e, (n.object as? AVAudioEngine) === e else { return }
            let input = e.inputNode
            let format = input.outputFormat(forBus: 0)
            var retapped = false
            if let conv, format.sampleRate > 0, conv.inputFormat != format, let c = AVAudioConverter(from: format, to: target) {
                c.downmix = true
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, when in self?.consume(buf, when) }
                lock.lock(); converter = c; lock.unlock()
                retapped = true
            }
            var restarted = false, playerReconnected = false
            if !e.isRunning {
                if let p { e.connect(p, to: e.mainMixerNode, format: playFormat) }
                do {
                    try e.start()
                    p?.play()
                    restarted = true
                    playerReconnected = p != nil
                } catch {
                    AppLog.shared.log("audio_restart_error", ["err": error.localizedDescription])
                }
            }
            let vp = input.isVoiceProcessingEnabled && !input.isVoiceProcessingBypassed
            lock.lock(); voiceProcessing = ambientMode && vp; lock.unlock()
            AppLog.shared.log("audio_config_change", ["route": Self.routeName, "retapped": retapped, "restarted": restarted,
                                                      "player_reconnected": playerReconnected, "in_rate": format.sampleRate, "vp": vp])
            onRouteChanged?()
        }
    }

    private func stopEngine() {
        lock.lock()
        let e = engine, p = player
        engine = nil
        player = nil
        converter = nil
        voiceProcessing = false
        levelBits = 0
        lock.unlock()
        guard let e else { return }
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: e)
        p?.stop()
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }

    /// With no consumer left: stop the engine and release the session (deactivation is also
    /// what lifts the ducking of other audio).
    private func stopIfIdle() {
        lock.lock()
        let idle = noteEncoder == nil && ambientSink == nil
        lock.unlock()
        guard idle else { return }
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: capture

    private func consume(_ buf: AVAudioPCMBuffer, _ when: AVAudioTime) {
        if HoldTiming.shared.wants("first_sample") {
            // When the first buffer's first sample was captured (host clock), and its length: the
            // tap hands over audio in blocks, so the first block arrives after it was recorded.
            if when.isHostTimeValid { HoldTiming.shared.mark("first_sample", uptime: AVAudioTime.seconds(forHostTime: when.hostTime)) }
            HoldTiming.shared.note("first_frames", buf.frameLength)
            HoldTiming.shared.note("in_rate", buf.format.sampleRate)
        }
        lock.lock()
        let conv = converter
        lock.unlock()
        guard let conv else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        if HoldTiming.shared.wants("first_buffer") { HoldTiming.shared.mark("first_buffer") }

        // Level: O(n) over samples already captured (no second sampler).
        var sum: Float = 0
        for s in samples { let v = Float(s) / 32768; sum += v * v }
        let scaled = min(1, (sum / Float(max(1, samples.count))).squareRoot() * 6)
        if scaled > 0, HoldTiming.shared.wants("first_signal") { HoldTiming.shared.mark("first_signal") }

        lock.lock()
        let prev = Float(bitPattern: levelBits)
        levelBits = (scaled > prev ? scaled : prev * 0.82 + scaled * 0.18).bitPattern
        let noteEnc = noteEncoder, ambEnc = ambientEncoder, sink = ambientSink
        lock.unlock()

        if let noteEnc, let packets = try? noteEnc.push(samples), !packets.isEmpty {
            lock.lock()
            if noteEncoder === noteEnc { notePackets.append(contentsOf: packets) }
            lock.unlock()
        }
        if let ambEnc, let sink, let packets = try? ambEnc.push(samples) {
            for p in packets { sink(p) }
        }
    }

    // MARK: hold-to-talk

    /// Starts a note without blocking the caller: the session and engine start on `configQueue`
    /// (measured: about 270 ms on the iPhone 17 Pro Max, mostly `AVAudioEngine.start`). `live`
    /// runs on the main queue once the input captures, i.e. when `start` returns (the first sample
    /// is captured a few ms before), or at once on an engine already running for ambient. The
    /// first tap buffer comes a 100 ms block later and is not waited for. `failed` runs on the
    /// main queue if it cannot start.
    func startNote(live: @escaping @Sendable () -> Void, failed: @escaping @Sendable (Error) -> Void) {
        configQueue.async { [self] in
            do {
                guard Self.permission == .granted else { throw Failure.permissionDenied }
                let enc: OpusVoiceEncoder
                do { enc = try OpusVoiceEncoder() } catch { throw Failure.opus("\(error)") }
                lock.lock()
                noteEncoder = enc
                notePackets.removeAll(keepingCapacity: true)
                let ambient = ambientSink != nil
                lock.unlock()
                try ensureEngine(ambient: ambient)
                HoldTiming.shared.note("other_audio", AVAudioSession.sharedInstance().isOtherAudioPlaying)
                DispatchQueue.main.async(execute: live)
            } catch {
                lock.lock(); noteEncoder = nil; lock.unlock()
                DispatchQueue.main.async { failed(error) }
            }
        }
    }

    /// Ends the hold after any pending start. `done` gets the packets (empty when cancelled) on
    /// the main queue before the engine stops, so the send does not wait for the session to
    /// deactivate.
    func stopNote(keep: Bool, done: @escaping @Sendable ([Data]) -> Void) {
        configQueue.async { [self] in
            lock.lock()
            let packets = keep ? notePackets : []
            noteEncoder = nil
            notePackets = []
            lock.unlock()
            DispatchQueue.main.async { done(packets) }
            stopIfIdle()
        }
    }

    // MARK: ambient

    func startAmbient(_ sink: @escaping (Data) -> Void) throws {
        guard Self.permission == .granted else { throw Failure.permissionDenied }
        let enc: OpusVoiceEncoder
        do { enc = try OpusVoiceEncoder() } catch { throw Failure.opus("\(error)") }
        lock.lock()
        ambientEncoder = enc
        ambientSink = sink
        lock.unlock()
        do {
            try configQueue.sync { try ensureEngine(ambient: true) }
        } catch {
            lock.lock(); ambientEncoder = nil; ambientSink = nil; lock.unlock()
            throw error
        }
    }

    func stopAmbient() {
        lock.lock()
        ambientEncoder = nil
        ambientSink = nil
        lock.unlock()
        clearPlayback()
        lock.lock()
        let note = noteEncoder != nil
        lock.unlock()
        // A hold in progress keeps recording; the engine drops to plain mode at its end.
        if !note { configQueue.sync { stopIfIdle() } }
    }

    /// Rebuilds the engine in its current mode (route change, media services reset).
    func rebuild() throws {
        lock.lock()
        let ambient = ambientSink != nil, note = noteEncoder != nil
        lock.unlock()
        guard ambient || note else { return }
        try configQueue.sync {
            stopEngine()
            try ensureEngine(ambient: ambient)
        }
    }

    // MARK: playback

    /// Schedules 16 kHz samples; `done` runs when they have been played (not when scheduled).
    func schedule(_ samples: [Int16], done: @escaping () -> Void) -> Bool {
        lock.lock()
        let p = player
        lock.unlock()
        guard let p, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return false
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let dst = buf.floatChannelData![0]
        for i in 0..<samples.count { dst[i] = Float(samples[i]) / 32768 }
        p.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in done() }
        return true
    }

    /// Drops everything scheduled. Completion callbacks of the dropped buffers still fire; the
    /// edge machine ignores them by generation.
    func clearPlayback() {
        lock.lock()
        let p = player
        lock.unlock()
        guard let p else { return }
        p.stop()
        p.play()
    }
}
