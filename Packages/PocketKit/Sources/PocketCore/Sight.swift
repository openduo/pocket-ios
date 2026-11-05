// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Sight on the phone (docs/design/sight.md): when the room's cerebellum asks the capture master
/// for a camera, a standing phone answers with its camera, and a closed phone in a hand answers
/// when the user turns its camera on. Pure: the decision, the ask, the declines and the binary
/// uplink frames; the app owns the camera and the encoder.

/// What the cerebellum asks of the room's camera: the channel's `camera.capture`. Every value is
/// the cerebellum's; the phone applies them and invents none. Sight is H.264 video only.
public struct SightAsk: Equatable, Sendable {
    public struct Video: Equatable, Sendable {
        /// WebCodecs H.264 codec string, `avc1.` and the profile, constraint and level bytes.
        public var codec: String
        /// The ceiling of the frame rate.
        public var fps: Int
        /// The floor: the phone adapts down to it, never below it.
        public var minFps: Int
        /// The ceiling of the bitrate, bit/s.
        public var bitrate: Int
        public var keyIntervalMs: Double

        public init(codec: String, fps: Int, minFps: Int, bitrate: Int, keyIntervalMs: Double) {
            self.codec = codec; self.fps = fps; self.minFps = minFps; self.bitrate = bitrate
            self.keyIntervalMs = keyIntervalMs
        }

        /// The `profile_idc` byte of `codec`.
        public var profile: UInt8? {
            guard codec.hasPrefix("avc1."), codec.count == 11 else { return nil }
            return UInt8(codec.dropFirst(5).prefix(2), radix: 16)
        }
    }

    /// The asked size, landscape. A phone held upright sends it with width and height swapped.
    public var width: Int
    public var height: Int
    public var video: Video

    public init(width: Int, height: Int, video: Video) {
        self.width = width; self.height = height; self.video = video
    }

    /// Reads `camera.capture`; nil when it is not a valid video ask (a size outside 1 to 65535, no
    /// video, a rate that is not an integer, no floor, a floor above the rate).
    public init?(_ c: [String: Any]) {
        let sizes = 1...Int(UInt16.max)
        guard let width = Wire.integer(c["width"]), sizes.contains(width),
              let height = Wire.integer(c["height"]), sizes.contains(height),
              let v = c["video"] as? [String: Any], let codec = v["codec"] as? String,
              codec.range(of: #"^avc1\.[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil,
              let fps = Wire.integer(v["fps"]), fps > 0,
              let minFps = Wire.integer(v["min_fps"]), minFps > 0, minFps <= fps,
              let bitrate = Wire.integer(v["bitrate"]), bitrate > 0,
              let key = Wire.number(v["key_interval_ms"]), key > 0 else { return nil }
        self.init(width: width, height: height,
                  video: Video(codec: codec, fps: fps, minFps: minFps, bitrate: bitrate, keyIntervalMs: key))
    }

    /// The rate to encode at. Normally the asked ceiling. At the serious thermal state the floor,
    /// with the bitrate scaled by the same ratio so each frame keeps its bits. The camera's format
    /// bounds it: a floor below the format's slowest rate runs at that rate, a ceiling above its
    /// fastest at that one; either way it stays within the ask's range.
    public func rate(_ thermal: SightThermal, deviceMinFps: Double = 0, deviceMaxFps: Double = .infinity) -> SightRate {
        let v = video
        let wanted = thermal == .normal ? v.fps : v.minFps
        let top = deviceMaxFps.isFinite ? min(v.fps, Int(deviceMaxFps.rounded(.down))) : v.fps
        let fps = max(v.minFps, min(top, max(wanted, Int(deviceMinFps.rounded(.up)))))
        return SightRate(fps: fps, bitrate: max(1, v.bitrate * fps / v.fps))
    }
}

/// The rate the phone declares on the wire: integer frames per second and its encoder's target
/// bitrate, within the ask's range.
public struct SightRate: Equatable, Sendable {
    public var fps: Int
    public var bitrate: Int

    public init(fps: Int, bitrate: Int) { self.fps = fps; self.bitrate = bitrate }
}

/// What the camera looks at, sent with the video so the judge and the brain read them right.
public enum SightView: String, Equatable, Sendable {
    /// Where the screen faces: the person talking to 多多 (the outer front camera in the tent).
    case facing
    /// The room, seen from the device (the rear camera on the table).
    case room
}

public enum SightCamera: Equatable, Sendable {
    /// The outer display's front camera.
    case outerFront
    /// The rear main camera.
    case rear

    public var view: SightView { self == .outerFront ? .facing : .room }
}

/// How the phone stands. A standing phone sees by default; a closed phone in a hand sees only when
/// the user turns the camera on and points it; a phone open flat in a hand does not see.
public enum SightPosture: Equatable, Sendable {
    /// The outer display facing the person, standing: half-folded, or closed on a charging stand.
    case tent
    /// Half-folded on a table, the inner display's upper half upright. `camerasUp` is false when
    /// the rear cameras are on the half lying on the table.
    case tabletop(camerasUp: Bool)
    /// The outer display in a hand (the closed phone, or an iPhone that does not fold): the camera
    /// on request, front or rear.
    case hand
    /// The inner display open in a hand: no sight.
    case open
}

extension SightPosture {
    /// From the layout, the hinge and the power. The tent layout also covers the closed phone held
    /// sideways, which does not stand: a half-open hinge, or power while closed and sideways (a
    /// MagSafe or charging stand), makes it a tent.
    /// `camerasUp`: whether the rear cameras' half is the upright one on the table.
    public static func from(layout: DuoLayout, halfOpen: Bool, charging: Bool = false,
                            camerasUp: Bool = true) -> SightPosture {
        switch layout {
        case .tabletop: .tabletop(camerasUp: camerasUp)
        case .tent: halfOpen || charging ? .tent : .hand
        case .phone: .hand
        case .side, .stacked: .open
        }
    }
}

public enum SightPause: Equatable, Sendable {
    case background
    /// Another app or a call holds the camera.
    case taken
    /// The system's thermal state is critical.
    case hot
    /// Tabletop with the rear cameras on the lying half.
    case wrongHalf
}

/// Why an asked camera could not start. Each is the reason of the `camera_declined` it sends.
public enum SightFailure: String, Error, Equatable, Sendable {
    /// The encoder does not take the asked codec at the asked size.
    case noH264 = "no_h264"
    /// The phone has no camera of the needed kind.
    case noCamera = "no_camera"
    /// The camera has no format at the asked size and rate.
    case noFormat = "no_format"
    /// The camera input could not join the session: another app holds it. Tried again on the
    /// next change.
    case cameraTaken = "camera_taken"
    /// The encoder failed while running. Tried again on the next change.
    case encoderFailed = "encoder_failed"

    /// Tried again on the next change of what decides sight; the others hold until a new ask.
    public var retried: Bool { self == .cameraTaken || self == .encoderFailed }
}

public enum SightState: Equatable, Sendable {
    /// No ask, not the capture master, or ambient mode off.
    case notOffered
    /// The room can see, but the phone is open in a hand: say how to stand it up.
    case hint
    /// Offered and switched off.
    case off
    /// The camera-permission prompt is up.
    case asking
    /// Video leaves the phone.
    case on(camera: SightCamera)
    case paused(SightPause)
    /// Camera access refused.
    case denied
    /// The camera could not start.
    case failed(SightFailure)
    /// The channel stopped the camera for this phone; the reason is the channel's.
    case refused(String)

    /// The camera control is shown.
    public var offered: Bool {
        switch self {
        case .notOffered, .hint, .refused: false
        case .off, .asking, .on, .paused, .denied, .failed: true
        }
    }

    public var camera: SightCamera? { if case .on(let c) = self { c } else { nil } }

    /// The `camera_declined` reason for an asked camera that does not run; nil while it runs, while
    /// the permission prompt is up, and when nothing is asked.
    public var declineReason: String? {
        switch self {
        case .notOffered, .asking, .on, .refused: nil
        case .hint, .paused(.wrongHalf): "posture"
        case .off: "user_off"
        case .paused(.background): "background"
        case .paused(.taken): "camera_taken"
        case .paused(.hot): "thermal"
        case .denied: "camera_denied"
        case .failed(let f): f.rawValue
        }
    }
}

public enum SightThermal: Equatable, Sendable {
    /// Nominal or fair.
    case normal
    /// The level at which Apple asks apps to reduce work: video drops to the ask's floor.
    case serious
    case critical
}

/// A camera that could not start, and why. It holds for that camera until a new ask; a held
/// camera is tried again on the next change.
public struct SightStartFailure: Equatable, Sendable {
    public var camera: SightCamera
    public var failure: SightFailure

    public init(camera: SightCamera, failure: SightFailure) { self.camera = camera; self.failure = failure }
}

public struct SightInputs: Equatable, Sendable {
    public var ask: SightAsk?
    /// The channel stopped the camera for this phone (`camera` off with a `reason`).
    public var refused: String?
    /// This connection holds the room's capture seat.
    public var master = false
    public var posture = SightPosture.hand
    /// The switch for a standing phone, remembered on this phone (on by default).
    public var enabled = true
    /// The switch in a hand, for this ambient session (off by default).
    public var handOn = false
    /// The camera in a hand, remembered on this phone (the front by default).
    public var handCamera = SightCamera.outerFront
    public var active = false
    /// nil while the user has not been asked.
    public var authorized: Bool?
    /// The permission prompt is up.
    public var prompting = false
    public var taken = false
    /// The system stopped the camera under pressure (heat or peak power), until it lets go.
    public var pressure = false
    public var thermal = SightThermal.normal
    public var failure: SightStartFailure?

    public init() {}

    public var state: SightState {
        guard master else { return .notOffered }
        guard ask != nil else { return refused.map(SightState.refused) ?? .notOffered }
        // No decline while the permission prompt is up, whatever else changes under it.
        if prompting { return .asking }
        let camera: SightCamera
        switch posture {
        case .open: return .hint
        case .hand:
            guard handOn else { return .off }
            camera = handCamera
        case .tent:
            guard enabled else { return .off }
            camera = .outerFront
        case .tabletop:
            guard enabled else { return .off }
            camera = .rear
        }
        if case .tabletop(camerasUp: false) = posture { return .paused(.wrongHalf) }
        if authorized == false { return .denied }
        if !active { return .paused(.background) }
        if taken { return .paused(.taken) }
        if thermal == .critical || pressure { return .paused(.hot) }
        if let failure, failure.camera == camera { return .failed(failure.failure) }
        if authorized == nil { return .asking }
        return .on(camera: camera)
    }
}

/// The `camera_declined` frames of one ask: one when the asked camera does not run, and one more
/// each time the reason changes while it does not. Video resuming ends the run of declines.
public struct SightDeclines: Equatable, Sendable {
    private var sent: String?

    public init() {}

    /// The reason to send now for `state`, if any: a reason is sent once, until video resumes.
    public mutating func reason(for state: SightState) -> String? {
        guard let r = state.declineReason, r != sent else { return nil }
        sent = r
        return r
    }

    /// A key frame was sent: video resumed, and the next decline is new.
    public mutating func resumed() { sent = nil }
}

/// The edge link's binary framing once the channel confirms `media` (the kind byte).
public enum MediaFraming {
    public static let audio: UInt8 = 0x01
    public static let video: UInt8 = 0x02

    /// Puts the audio kind byte in front of each packet of a capture block: `lengthPrefixed` is
    /// each Opus packet behind its length as a big-endian UInt16 (the bridge's layout), and so is
    /// the result. Nil when a length runs past the end.
    public static func audio(lengthPrefixed d: Data) -> Data? {
        var out = Data(capacity: d.count + d.count / 8)
        var i = d.startIndex
        while i < d.endIndex {
            guard d.endIndex - i >= 2 else { return nil }
            let n = Int(d[i]) << 8 | Int(d[i + 1])
            let start = i + 2
            guard n > 0, d.endIndex - start >= n, n + 1 <= Int(UInt16.max) else { return nil }
            out.append(UInt8((n + 1) >> 8))
            out.append(UInt8((n + 1) & 0xff))
            out.append(audio)
            out.append(d[start..<(start + n)])
            i = start + n
        }
        return out
    }
}

/// The `media` marker of `/live`: the phone offers the framing version it speaks, and the first
/// `meta` answers with the version both use.
public enum LiveMedia {
    public static let param = "media"
    /// The framing version this app speaks.
    public static let version = 1

    public enum Answer: Equatable, Sendable {
        /// No marker offered, or no answer: one Opus packet per binary frame, and no camera.
        case unframed
        case framed(Int)
        /// The answer is not a version the phone offered: the two ends disagree on framing.
        case invalid(String)
    }

    /// The first `meta`'s `media`, against what this connection offered.
    public static func answer(_ v: Any?, offered: Int?) -> Answer {
        // Present means answered: a null is an answer that is not a version.
        guard let offered, let v else { return .unframed }
        guard let n = Wire.integer(v), n >= 1, n <= offered else { return .invalid("meta.media=\(v), offered \(offered)") }
        return .framed(n)
    }
}

/// The uplink video of one connection: every chunk numbered (`seq`, from 0, never restarting on
/// this connection), stamped with a capture time that only moves forward, its decoder config on
/// key frames and its rate config on key frames and wherever the rate changes. Chunks too large
/// for the channel's bound are not sent; the next one sent is a key frame.
public struct SightUplink: Equatable, Sendable {
    /// The next chunk's `seq`: every chunk counts, sent or not, so the receiver sees a gap.
    public private(set) var seq: UInt32 = 0
    /// A chunk was not sent: the next chunk must be a key frame.
    public private(set) var needsKey = false
    private var lastAt: UInt64?
    /// The rate the receiver was last told.
    private var declared: SightRate?

    public init() {}

    /// Starting at `seq`, with `declared` as the rate already told, for tests.
    init(seq: UInt32, declared: SightRate? = nil) {
        self.seq = seq
        self.declared = declared
    }

    /// A new encoder's output follows: nothing but a key frame goes next, so its deltas never join
    /// the previous encoder's chain.
    public mutating func expectKey() { needsKey = true }

    /// The binary video frame for one encoded chunk (one Annex B access unit), or nil when it is
    /// not sent: larger than `maxFrameBytes`, or a delta frame while a key frame is due. `at` is
    /// the run's capture clock; on the wire it is at least the last one sent plus one.
    public mutating func video(key: Bool, at: Int, payload: Data, width: Int, height: Int, view: SightView,
                               rate: SightRate, maxFrameBytes: Int) -> Data? {
        let n = seq
        seq &+= 1
        if needsKey, !key { return nil }
        let stamp = max(UInt64(max(0, at)), lastAt.map { $0 + 1 } ?? 0)
        let withRate = key || rate != declared
        var flags: UInt8 = 0
        if key { flags |= 0x01 }
        if withRate { flags |= 0x02 }
        var f = Data([MediaFraming.video, flags])
        f.appendLittleEndian(n)
        f.appendLittleEndian(stamp)
        if key { f.appendBlock(["width": width, "height": height, "view": view.rawValue]) }
        if withRate { f.appendBlock(["fps": rate.fps, "bitrate": rate.bitrate]) }
        f.append(payload)
        guard f.count <= maxFrameBytes else {
            needsKey = true
            return nil
        }
        if key { needsKey = false }
        lastAt = stamp
        declared = rate
        return f
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    /// A config block: its length as a little-endian UInt16, then the object as UTF-8 JSON.
    mutating func appendBlock(_ object: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        appendLittleEndian(UInt16(json.count))
        append(json)
    }
}

/// Number readers for wire JSON (`JSONSerialization` values).
enum Wire {
    /// An integer, including a whole double; not a boolean.
    static func integer(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

/// The edge's wall clock at capture, kept for one camera run: read once at the run's first frame,
/// then carried forward on the camera's own frame times. `SightUplink` keeps it moving forward
/// across runs of one connection.
public struct SightClock: Equatable, Sendable {
    private var anchor: (wallMs: Double, frameS: Double)?

    public init() {}

    /// `frameS`: the frame's presentation time in seconds on the capture clock; `nowWallMs` and
    /// `nowFrameS`: the wall clock and the capture clock read together now.
    public mutating func at(frameS: Double, nowWallMs: Double, nowFrameS: Double) -> Int {
        if anchor == nil { anchor = (nowWallMs - (nowFrameS - frameS) * 1000, frameS) }
        let a = anchor!
        return max(0, Int((a.wallMs + (frameS - a.frameS) * 1000).rounded()))
    }

    public static func == (a: SightClock, b: SightClock) -> Bool {
        a.anchor?.wallMs == b.anchor?.wallMs && a.anchor?.frameS == b.anchor?.frameS
    }
}

/// H.264 from the encoder's length-prefixed form (AVCC) to the Annex B byte stream the protocol
/// carries, with the parameter sets in front of each key frame.
public enum AnnexB {
    public static let startCode = Data([0, 0, 0, 1])

    /// Nil when a length runs past the end.
    public static func from(avcc: Data, lengthSize: Int = 4, parameterSets: [Data] = []) -> Data? {
        var out = Data()
        for p in parameterSets { out += startCode + p }
        let bytes = [UInt8](avcc)
        var i = 0
        while i < bytes.count {
            guard i + lengthSize <= bytes.count else { return nil }
            var n = 0
            for k in 0..<lengthSize { n = n << 8 | Int(bytes[i + k]) }
            i += lengthSize
            guard n > 0, i + n <= bytes.count else { return nil }
            out += startCode + Data(bytes[i..<(i + n)])
            i += n
        }
        return out
    }
}
