// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import PocketCore
import VideoToolbox

/// The camera and the encoder of one sight run (docs/design/sight.md): the asked camera at the
/// asked size, at the rate the thermal state allows, encoded in hardware as the ask's H.264 and
/// stamped on the run's capture clock. Each chunk goes to `onChunk` with its run, so the
/// controller numbers only the current run's output. Runs on its own queue; the callbacks are
/// called there.
final class SightCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// One encoded access unit (Annex B) of a run, and the rate it was encoded at.
    struct Chunk {
        let run: Int
        /// The run's encoder: a turn to a new size starts a new one.
        let encoder: Int
        let key: Bool
        let at: Int
        let payload: Data
        let width: Int
        let height: Int
        let rate: SightRate
    }

    let session = AVCaptureSession()
    let camera: SightCamera
    let run: Int
    private let queue = DispatchQueue(label: "pocket.sight", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let device: AVCaptureDevice
    private let ask: SightAsk
    /// The slowest and the fastest rate the chosen format runs.
    private let deviceMinFps: Double
    private let deviceMaxFps: Double
    /// Stopped, or its encoder failed: frames still queued are not encoded.
    private var stopped = false
    private var rate: SightRate
    private var encoder: H264Encoder?
    /// Counts encoders: a replaced or stopped encoder's late output is dropped.
    private var encoderGen = 0
    private var clock = SightClock()
    private var forceKey = false
    private let busy: () -> Bool
    private let onChunk: (Chunk) -> Void
    private let onFailure: (SightFailure) -> Void
    /// The thermal record: frames encoded, frames skipped while the uplink was busy, bytes.
    private var encoded = 0
    private var skipped = 0
    private var bytes = 0
    private var began: Date?
    private var thermalObserver: NSObjectProtocol?
    /// Keeps the frames level with the horizon however the phone stands.
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// Opens the camera for the ask, or throws why it cannot (`SightFailure`).
    init(camera: SightCamera, ask: SightAsk, thermal: SightThermal, run: Int, busy: @escaping () -> Bool,
         onChunk: @escaping (Chunk) -> Void, onFailure: @escaping (SightFailure) -> Void) throws {
        self.camera = camera
        self.ask = ask
        self.run = run
        self.busy = busy
        self.onChunk = onChunk
        self.onFailure = onFailure
        // The encoder must take the asked codec at the asked size, landscape or upright.
        guard H264Encoder.supports(width: ask.width, height: ask.height, video: ask.video)
            || H264Encoder.supports(width: ask.height, height: ask.width, video: ask.video) else {
            AppLog.shared.log("sight_start_failed", ["why": "no_h264", "codec": ask.video.codec])
            throw SightFailure.noH264
        }
        guard let device = Self.device(camera) else {
            AppLog.shared.log("sight_start_failed", ["why": "no_camera", "camera": "\(camera)"])
            throw SightFailure.noCamera
        }
        guard let format = Self.format(device, ask: ask) else {
            AppLog.shared.log("sight_start_failed", ["why": "no_format", "w": ask.width, "h": ask.height,
                                                     "fps": ask.video.fps])
            throw SightFailure.noFormat
        }
        self.device = device
        deviceMinFps = format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 0
        deviceMaxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        rate = ask.rate(thermal, deviceMinFps: deviceMinFps, deviceMaxFps: deviceMaxFps)
        super.init()
        // The judge wants the whole field, the same every turn: no framing that follows faces.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input),
              session.canAddOutput(output) else {
            session.commitConfiguration()
            AppLog.shared.log("sight_start_failed", ["why": "camera_taken", "camera": "\(camera)"])
            throw SightFailure.cameraTaken
        }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        // After the input joins the session: adding it resets the device's frame durations.
        guard (try? device.lockForConfiguration()) != nil else {
            session.commitConfiguration()
            AppLog.shared.log("sight_start_failed", ["why": "camera_taken", "camera": "\(camera)"])
            throw SightFailure.cameraTaken
        }
        device.activeFormat = format
        _ = Self.setFrameRate(device, rate.fps)
        device.unlockForConfiguration()
        session.commitConfiguration()
        let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = r
        setRotation(r.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = r.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] r, _ in
            self?.setRotation(r.videoRotationAngleForHorizonLevelCapture)
        }
        AppLog.shared.log("sight_camera", ["camera": "\(camera)", "device": device.localizedName, "run": run,
                                           "w": ask.width, "h": ask.height, "fps": rate.fps, "bitrate": rate.bitrate,
                                           "device_fps": 1 / device.activeVideoMinFrameDuration.seconds,
                                           "device_min_fps": deviceMinFps])
    }

    func start() {
        queue.async { [self] in
            began = Date()
            session.startRunning()
            record("start")
        }
        // How fast the phone warms at the rate it runs.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.record("thermal") }
        }
    }

    func stop() {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        queue.async { [self] in
            stopped = true
            session.stopRunning()
            encoder?.invalidate()
            encoder = nil
            encoderGen += 1
            record("stop")
        }
    }

    /// The receiver lost a chunk: the next frame is a key frame.
    func forceKeyFrame() { queue.async { [self] in forceKey = true } }

    /// The thermal state changed: the camera and the encoder change their rate in place, with no
    /// key frame. The first chunk encoded at the new rate carries it.
    func setThermal(_ thermal: SightThermal) {
        queue.async { [self] in
            let r = ask.rate(thermal, deviceMinFps: deviceMinFps, deviceMaxFps: deviceMaxFps)
            guard r != rate else { return }
            // The camera's rate first: a rate the camera does not run is never declared.
            guard (try? device.lockForConfiguration()) != nil else {
                AppLog.shared.log("sight_rate_failed", ["run": run, "fps": r.fps])
                return
            }
            let set = Self.setFrameRate(device, r.fps)
            device.unlockForConfiguration()
            guard set else { return }
            rate = r
            encoder?.setRate(r)
            AppLog.shared.log("sight_rate", ["run": run, "fps": r.fps, "bitrate": r.bitrate, "thermal": "\(thermal)"])
        }
    }

    /// The thermal state with what the run has encoded so far: elapsed time, frames, frames skipped
    /// while the uplink was busy, and the achieved rate and bitrate. On the capture queue.
    private func record(_ why: String) {
        let s = began.map { Date().timeIntervalSince($0) } ?? 0
        let state = ProcessInfo.processInfo.thermalState
        AppLog.shared.log("sight_thermal", [
            "why": why, "thermal": ["nominal", "fair", "serious", "critical"][min(state.rawValue, 3)],
            "run": run, "s": Int(s), "encoded": encoded, "skipped": skipped, "declared_fps": rate.fps,
            "fps": s > 0 ? Double(encoded) / s : 0, "kbps": s > 0 ? Double(bytes) * 8 / s / 1000 : 0,
        ])
    }

    /// Turns the frames upright for the way the phone stands: the angle the system computes for a
    /// level horizon. A quarter turn makes the frames upright (the asked size swapped) and starts a
    /// new encoder, whose first chunk is a key frame.
    private func setRotation(_ angle: CGFloat) {
        queue.async { [self] in
            guard let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) else { return }
            c.videoRotationAngle = angle
        }
    }

    // MARK: device

    private static func device(_ camera: SightCamera) -> AVCaptureDevice? {
        switch camera {
        case .rear: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .outerFront: AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    /// A format at the asked size, either way round (frames are turned upright for the way the
    /// phone stands), that runs a rate in the ask's range: one that runs the asked rate, else the
    /// one that runs fastest within the range.
    private static func format(_ d: AVCaptureDevice, ask: SightAsk) -> AVCaptureDevice.Format? {
        let fps = Double(ask.video.fps), floor = Double(ask.video.minFps)
        let sized = d.formats.filter { f in
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let w = Int(dims.width), h = Int(dims.height)
            return (w == ask.width && h == ask.height) || (w == ask.height && h == ask.width)
        }
        if let f = sized.first(where: { $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate } }) {
            return f
        }
        func fastest(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.filter { $0.minFrameRate <= fps && floor <= $0.maxFrameRate }
                .map { min(fps, $0.maxFrameRate) }.max() ?? 0
        }
        return sized.filter { fastest($0) >= floor }.max { fastest($0) < fastest($1) }
    }

    /// Locks the device to `fps` when its format runs that rate; false when it does not (setting
    /// an unsupported duration raises). The device must be locked for configuration.
    @discardableResult
    private static func setFrameRate(_ d: AVCaptureDevice, _ fps: Int) -> Bool {
        let f = Double(fps)
        guard d.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= f && f <= $0.maxFrameRate })
        else {
            AppLog.shared.log("sight_rate_unsupported", ["fps": fps])
            return false
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        d.activeVideoMinFrameDuration = duration
        d.activeVideoMaxFrameDuration = duration
        return true
    }

    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        // Bytes still wait to leave: skip this frame before it costs an encode, as the web edge
        // does. The declared rate stays; the frames' times show the gap.
        if busy() {
            skipped += 1
            return
        }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        if encoder == nil || encoder?.width != w || encoder?.height != h {
            encoder?.invalidate()
            encoderGen += 1
            let gen = encoderGen
            // A new encoder is a new run of the clock: it re-anchors at its first frame.
            clock = SightClock()
            encoder = H264Encoder(width: w, height: h, video: ask.video, rate: rate) { [weak self] result in
                self?.chunk(result, width: w, height: h, gen: gen)
            }
            if encoder == nil {
                // Both sizes were checked at the start: this is a failure while running.
                AppLog.shared.log("sight_encoder_failed", ["w": w, "h": h, "why": "create"])
                stopped = true
                onFailure(.encoderFailed)
                return
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let at = clock.at(frameS: pts.seconds, nowWallMs: Date().timeIntervalSince1970 * 1000, nowFrameS: now.seconds)
        let key = forceKey
        forceKey = false
        encoder?.encode(pixels, pts: pts, at: at, rate: rate, forceKey: key)
    }

    private func chunk(_ result: H264Encoder.Output, width: Int, height: Int, gen: Int) {
        queue.async { [self] in
            guard gen == encoderGen, !stopped else { return }
            guard case .chunk(let annexB, let key, let at, let rate) = result else {
                // The encoder stopped working: the camera does not run until the next change.
                if case .failed(let status) = result {
                    AppLog.shared.log("sight_encoder_failed", ["run": run, "why": "encode", "status": Int(status)])
                }
                stopped = true
                encoder?.invalidate()
                encoder = nil
                encoderGen += 1
                onFailure(.encoderFailed)
                return
            }
            encoded += 1
            bytes += annexB.count
            onChunk(Chunk(run: run, encoder: gen, key: key, at: at, payload: annexB, width: width, height: height,
                          rate: rate))
        }
    }
}

/// H.264 in hardware (VideoToolbox) at the ask's profile and key interval and the run's rate and
/// bitrate, with no reordered frames, handing out Annex B chunks.
final class H264Encoder: @unchecked Sendable {
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    /// One encoded frame, or a failed encode.
    enum Output {
        /// Annex B, whether it is a key frame, the frame's capture time, the rate it was encoded at.
        case chunk(Data, key: Bool, at: Int, rate: SightRate)
        case failed(OSStatus)
    }

    private let out: (Output) -> Void

    /// The VideoToolbox profile for an H.264 `profile_idc`; the level follows the size and rate.
    static func profile(for idc: UInt8?) -> CFString? {
        switch idc {
        case 0x42: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case 0x4D: kVTProfileLevel_H264_Main_AutoLevel
        case 0x64: kVTProfileLevel_H264_High_AutoLevel
        default: nil
        }
    }

    /// Whether the hardware encoder takes the ask's codec at this size.
    static func supports(width: Int, height: Int, video: SightAsk.Video) -> Bool {
        guard let e = H264Encoder(width: width, height: height, video: video,
                                  rate: SightRate(fps: video.fps, bitrate: video.bitrate), out: { _ in }) else {
            return false
        }
        e.invalidate()
        return true
    }

    init?(width: Int, height: Int, video: SightAsk.Video, rate: SightRate, out: @escaping (Output) -> Void) {
        self.width = width
        self.height = height
        self.out = out
        guard let profile = Self.profile(for: video.profile) else { return nil }
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: video.keyIntervalMs / 1000,
        ]
        for (k, v) in props {
            guard VTSessionSetProperty(s, key: k, value: v as CFTypeRef) == noErr else {
                VTCompressionSessionInvalidate(s)
                return nil
            }
        }
        session = s
        setRate(rate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// The target bitrate and the expected frame rate, in place.
    func setRate(_ r: SightRate) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: r.bitrate as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: r.fps as CFTypeRef)
    }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime, at: Int, rate: SightRate, forceKey: Bool) {
        guard let session else { return }
        let options: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: options,
                                                     infoFlagsOut: nil) { [out] status, flags, buffer in
            // A frame the encoder chose to drop is not a failure.
            if status == noErr, buffer == nil || flags.contains(.frameDropped) { return }
            guard status == noErr, let buffer, let chunk = Self.annexB(buffer) else { return out(.failed(status)) }
            out(.chunk(chunk.data, key: chunk.key, at: at, rate: rate))
        }
        if status != noErr { out(.failed(status)) }
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private static func annexB(_ buffer: CMSampleBuffer) -> (data: Data, key: Bool)? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let block = CMSampleBufferGetDataBuffer(buffer), let format = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        let avcc = Data(bytes: pointer, count: length)
        var sets: [Data] = []
        var nalLength: Int32 = 4
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: &nalLength)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                      parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let p {
                    sets.append(Data(bytes: p, count: n))
                }
            }
        }
        guard let data = AnnexB.from(avcc: avcc, lengthSize: Int(nalLength), parameterSets: sets) else { return nil }
        return (data, key)
    }
}
