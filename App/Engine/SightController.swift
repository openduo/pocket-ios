// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import Foundation
import PocketCore
import UIKit

/// Sight on this phone (docs/design/sight.md). Collects what decides it (the cerebellum's ask,
/// the capture seat, how the phone stands, the switch, the app in front, camera access, the camera
/// held by another app, the thermal state), keeps `SightInputs.state`, runs the camera while that
/// state is `.on`, and says why when an asked camera does not run (`camera_declined`). It numbers
/// the current run's chunks for the connection (`SightUplink`); a stopped run's late output is
/// dropped. All state lives on `queue`.
final class SightController: @unchecked Sendable {
    static let shared = SightController()

    private let queue = DispatchQueue(label: "pocket.sight.control", qos: .userInitiated)
    private var inputs = SightInputs()
    private var maxFrameBytes = 0
    private var capture: SightCapture?
    /// The state the running capture was started for.
    private var running: SightState?
    /// Counts camera runs; only the current run's chunks are numbered and sent.
    private var run = 0
    /// The run and encoder of the last chunk numbered: a new one must start with a key frame.
    private var lastStream: (run: Int, encoder: Int)?
    /// The connection's video numbering and clock floor; a new connection starts a new one.
    private var uplink = SightUplink()
    private var declines = SightDeclines()
    /// The capture is kept through a pause the system made (another app, system pressure).
    private var held = false

    private let lock = NSLock()
    private var current = SightState.notOffered
    private var currentHand = false
    private var currentSession: AVCaptureSession?
    /// Called on `queue` after the state changed.
    var onChange: (() -> Void)?

    private static let enabledKey = "sight.enabled"
    private static let handCameraKey = "sight.handCamera"

    private init() {
        inputs.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        inputs.handCamera = UserDefaults.standard.string(forKey: Self.handCameraKey) == "rear" ? .rear : .outerFront
        inputs.authorized = Self.authorization()
        inputs.thermal = Self.thermal()
        let nc = NotificationCenter.default
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.update { $0.thermal = Self.thermal() }
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] n in
            let raw = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init)
            // In the background the scene phase already pauses.
            let pause: SightPause? = switch reason {
            case .videoDeviceInUseByAnotherClient, .videoDeviceNotAvailableWithMultipleForegroundApps: .taken
            case .videoDeviceNotAvailableDueToSystemPressure: .hot
            default: nil
            }
            self?.interruption(of: n.object, pause: pause, log: ["reason": raw ?? -1])
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] n in
            self?.interruption(of: n.object, pause: nil, log: nil)
        }
        // The session failed to start or stopped with an error (media services reset among them):
        // the system ended the camera.
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] n in
            let error = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.runtimeError(of: n.object, code: error?.code ?? 0)
        }
    }

    var state: SightState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// The phone is in a hand: the camera can be turned to the rear, and the rear one shows a
    /// viewfinder.
    var inHand: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentHand
    }

    /// The running camera's session, for the viewfinder.
    var session: AVCaptureSession? {
        lock.lock(); defer { lock.unlock() }
        return currentSession
    }

    // MARK: inputs

    /// Only the running session's interruptions count: a session already stopped (a camera
    /// switch, a restart) may report the device in use by its successor, and may never report
    /// the end.
    /// `log` marks the start of an interruption, with `pause` the one that stops the camera; no
    /// `log` is its end.
    private func interruption(of session: Any?, pause: SightPause?, log: [String: Any]?) {
        queue.async { [self] in
            guard let capture, (session as AnyObject?) === capture.session else { return }
            if let log {
                AppLog.shared.log("sight_interrupted", log)
                if pause == .taken { update { $0.taken = true } }
                if pause == .hot { update { $0.pressure = true } }
            } else {
                update {
                    $0.taken = false
                    $0.pressure = false
                }
            }
        }
    }

    private func runtimeError(of session: Any?, code: Int) {
        queue.async { [self] in
            guard let capture, (session as AnyObject?) === capture.session else { return }
            AppLog.shared.log("sight_runtime_error", ["run": capture.run, "code": code])
            failed(.cameraTaken, run: capture.run)
        }
    }

    /// The channel's `camera` frame; nil stops. A stop the channel made for this phone carries
    /// its `reason`, shown until the next ask.
    func asked(_ ask: SightAsk?, maxFrameBytes: Int, reason: String?) {
        queue.async { [self] in
            AppLog.shared.log("sight_ask", ["on": ask != nil, "reason": reason ?? ""])
            // The same ask again on this connection keeps the camera: only changed values restart
            // it. The receiver gets a key frame to start from, and any decline again.
            if let ask, ask == inputs.ask, maxFrameBytes == self.maxFrameBytes {
                declines = SightDeclines()
                capture?.forceKeyFrame()
                apply()
                return
            }
            self.maxFrameBytes = maxFrameBytes
            // A new ask starts a new camera run, and its declines start over.
            running = nil
            inputs.ask = ask
            inputs.refused = ask == nil ? reason : nil
            inputs.failure = nil
            declines = SightDeclines()
            apply()
        }
    }

    /// The connection was replaced or closed: its ask, its numbering and its declines go with it.
    func connectionEnded() {
        queue.async { [self] in
            inputs.ask = nil
            inputs.refused = nil
            inputs.failure = nil
            uplink = SightUplink()
            lastStream = nil
            declines = SightDeclines()
            apply()
        }
    }

    func keyFrame() { queue.async { [self] in capture?.forceKeyFrame() } }

    func setMaster(_ master: Bool) { update { $0.master = master } }
    func setPosture(_ posture: SightPosture) { update { $0.posture = posture } }
    func setActive(_ active: Bool) {
        update {
            $0.active = active
            if active {
                // Access may have changed in Settings while the app was away; a prompt is over.
                $0.authorized = Self.authorization()
                $0.prompting = false
            }
        }
    }

    /// The 摄像头 control: in a hand it turns the camera on for this ambient session; standing it is
    /// the remembered switch.
    func toggle() {
        update { i in
            if i.posture == .hand {
                i.handOn.toggle()
                AppLog.shared.log("sight_switch", ["on": i.handOn, "hand": true])
            } else {
                i.enabled.toggle()
                UserDefaults.standard.set(i.enabled, forKey: Self.enabledKey)
                AppLog.shared.log("sight_switch", ["on": i.enabled, "hand": false])
            }
        }
    }

    /// Front to rear and back, in a hand.
    func flip() {
        update { i in
            i.handCamera = i.handCamera == .rear ? .outerFront : .rear
            UserDefaults.standard.set(i.handCamera == .rear ? "rear" : "front", forKey: Self.handCameraKey)
            AppLog.shared.log("sight_flip", ["camera": "\(i.handCamera)"])
        }
    }

    /// Ambient mode ended: the camera in a hand is off for the next session.
    func ambientEnded() { update { $0.handOn = false } }

    /// Applies only a real change: the ambient snapshot sets the capture seat on every publish.
    private func update(_ change: @escaping (inout SightInputs) -> Void) {
        queue.async { [self] in
            let before = inputs
            change(&inputs)
            guard inputs != before else { return }
            // A camera held by another app, or an encoder that failed, is tried again on the next
            // change.
            if inputs.failure?.failure.retried == true { inputs.failure = nil }
            apply()
        }
    }

    // MARK: the camera

    private func apply() {
        var state = inputs.state
        // Asked for the first time: show the prompt, and decide again with the answer.
        if state == .asking, inputs.authorized == nil, !inputs.prompting {
            inputs.prompting = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.update {
                    $0.authorized = granted
                    // The answer can come before the app is active again; until it is, the prompt
                    // still holds (no `background` decline for the moment it took).
                    if $0.active { $0.prompting = false }
                }
            }
        }
        // A camera the system interrupted (another app, system pressure) keeps its session, so the
        // end of the interruption reaches it and the camera resumes.
        let wasHeld = held
        held = capture != nil && (state == .paused(.taken) || (state == .paused(.hot) && inputs.pressure))
        if wasHeld, !held, state == running {
            // Resumed after the interruption: the receiver starts again from a key frame.
            uplink.expectKey()
            capture?.forceKeyFrame()
        }
        if state != running, !held {
            stopCapture()
            if case .on(let camera) = state, let ask = inputs.ask {
                run += 1
                let r = run
                do {
                    let c = try SightCapture(camera: camera, ask: ask, thermal: inputs.thermal, run: r,
                                             busy: { AmbientController.shared.uplinkBusy },
                                             onChunk: { [weak self] chunk in self?.queue.async { self?.chunk(chunk) } },
                                             onFailure: { [weak self] f in self?.queue.async { self?.failed(f, run: r) } })
                    capture = c
                    c.start()
                    running = state
                } catch {
                    inputs.failure = SightStartFailure(camera: camera, failure: error as? SightFailure ?? .cameraTaken)
                    state = inputs.state
                }
            }
        } else if !held {
            capture?.setThermal(inputs.thermal)
        }
        if let reason = declines.reason(for: state) { AmbientController.shared.sendDecline(reason) }
        lock.lock()
        let changed = current != state
        let hand = inputs.posture == .hand
        let handChanged = currentHand != hand
        current = state
        currentHand = hand
        currentSession = capture?.session
        lock.unlock()
        if changed { AppLog.shared.log("sight_state", ["state": "\(state)"]) }
        if changed || handChanged { onChange?() }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        running = nil
        // An interruption belongs to the stopped session, which never reports its end; the next
        // session reports its own.
        inputs.taken = false
        inputs.pressure = false
    }

    /// The running camera failed after it started: its encoder, or the session.
    private func failed(_ f: SightFailure, run r: Int) {
        guard r == run, let camera = capture?.camera else { return }
        inputs.failure = SightStartFailure(camera: camera, failure: f)
        apply()
    }

    /// One chunk of a run: numbered and sent when it is the current run's, else dropped.
    private func chunk(_ c: SightCapture.Chunk) {
        guard let capture, c.run == run, capture.run == c.run else { return }
        if lastStream.map({ $0.run != c.run || $0.encoder != c.encoder }) ?? true {
            lastStream = (c.run, c.encoder)
            uplink.expectKey()
        }
        let waiting = uplink.needsKey
        guard let frame = uplink.video(key: c.key, at: c.at, payload: c.payload, width: c.width, height: c.height,
                                       view: capture.camera.view, rate: c.rate, maxFrameBytes: maxFrameBytes) else {
            // Too large: the next chunk must be a key frame. A delta while one is due was already
            // asked for; asking again per delta in flight would make extra key frames.
            if c.key || !waiting { capture.forceKeyFrame() }
            return
        }
        AmbientController.shared.sendSight(frame)
        if c.key { declines.resumed() }
    }

    private static func authorization() -> Bool? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: nil
        default: false
        }
    }

    private static func thermal() -> SightThermal {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: .critical
        case .serious: .serious
        default: .normal
        }
    }
}
