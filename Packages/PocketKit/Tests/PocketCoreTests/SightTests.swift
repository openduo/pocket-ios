// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class SightTests: XCTestCase {
    let capture: [String: Any] = [
        "width": 1280, "height": 720,
        "video": ["codec": "avc1.42E01F", "fps": 25, "min_fps": 2, "bitrate": 1_200_000, "key_interval_ms": 2000],
    ]

    private func video(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var c = capture
        var v = c["video"] as! [String: Any]
        change(&v)
        c["video"] = v
        return c
    }

    // MARK: the ask

    func testReadsTheAsk() throws {
        let ask = try XCTUnwrap(SightAsk(capture))
        XCTAssertEqual(ask.width, 1280)
        XCTAssertEqual(ask.video.fps, 25)
        XCTAssertEqual(ask.video.minFps, 2)
        XCTAssertEqual(ask.video.bitrate, 1_200_000)
        XCTAssertEqual(ask.video.profile, 0x42)
        var stills = capture
        stills["video"] = nil
        XCTAssertNil(SightAsk(stills), "no stills: an ask without video is no ask")
        XCTAssertNil(SightAsk(video { $0["min_fps"] = nil }), "the floor is required")
        XCTAssertNil(SightAsk(video { $0["min_fps"] = 30 }), "a floor above the rate")
        XCTAssertNil(SightAsk(video { $0["fps"] = 25.5 }), "the rate is an integer")
        XCTAssertNil(SightAsk(video { $0["fps"] = true }), "a boolean is not a number")
        XCTAssertNil(SightAsk(video { $0["codec"] = "vp8" }))
        XCTAssertEqual(SightAsk(video { $0["fps"] = 25.0 }), ask, "a whole number is an integer")
        var huge = capture
        huge["width"] = 65536
        XCTAssertNil(SightAsk(huge), "a size is 1 to 65535")
    }

    func testTheRateFollowsTheThermalStateWithinTheAsk() throws {
        let ask = try XCTUnwrap(SightAsk(capture))
        XCTAssertEqual(ask.rate(.normal), SightRate(fps: 25, bitrate: 1_200_000))
        XCTAssertEqual(ask.rate(.serious), SightRate(fps: 2, bitrate: 96000), "the floor, bits per frame kept")
        XCTAssertEqual(ask.rate(.serious, deviceMinFps: 3), SightRate(fps: 3, bitrate: 144_000),
                       "a camera that cannot go that slow runs at its slowest")
        XCTAssertEqual(ask.rate(.serious, deviceMinFps: 60).fps, 25, "never above the ceiling")
        XCTAssertEqual(ask.rate(.normal, deviceMinFps: 1, deviceMaxFps: 15), SightRate(fps: 15, bitrate: 720_000),
                       "a camera that cannot reach the ceiling runs at its fastest")
    }

    // MARK: the edge

    func testTheEdgeTakesTheCameraOnlyOnAFramedConnection() throws {
        let ask = try XCTUnwrap(SightAsk(capture))
        var e = AmbientEdge(room: "r")
        XCTAssertEqual(e.frame(["type": "camera", "capture": capture, "max_frame_bytes": 1 << 20]),
                       [.send(["type": "camera_declined", "reason": "unframed_channel"]),
                        .camera(nil, maxFrameBytes: 0, reason: "unframed_channel")])
        e.framed = true
        XCTAssertEqual(e.frame(["type": "camera", "capture": capture, "max_frame_bytes": 1 << 20]),
                       [.camera(ask, maxFrameBytes: 1 << 20, reason: nil)])
        XCTAssertEqual(e.frame(["type": "camera", "capture": NSNull(), "max_frame_bytes": 1 << 20]),
                       [.camera(nil, maxFrameBytes: 1 << 20, reason: nil)])
        XCTAssertEqual(e.frame(["type": "camera", "capture": NSNull(), "reason": "nonconforming", "max_frame_bytes": 1 << 20]),
                       [.camera(nil, maxFrameBytes: 1 << 20, reason: "nonconforming")])
        for odd: Any in ["", NSNull(), 3] {
            XCTAssertEqual(e.frame(["type": "camera", "capture": NSNull(), "reason": odd, "max_frame_bytes": 1 << 20]),
                           [.camera(nil, maxFrameBytes: 1 << 20, reason: nil)], "a stop; only a non-empty string is shown")
        }
        XCTAssertEqual(e.frame(["type": "key_frame"]), [.keyFrame])
        guard case .warn = e.frame(["type": "camera", "capture": capture])[0] else { return XCTFail("no bound") }
        // Unframed, a start is declined before it is read: the old stills shape, with no bound,
        // too. A stop sends nothing.
        e.framed = false
        let stills: [String: Any] = ["width": 640, "height": 480, "fps": 1, "mime": "image/jpeg", "quality": 0.7]
        XCTAssertEqual(e.frame(["type": "camera", "capture": stills]),
                       [.send(["type": "camera_declined", "reason": "unframed_channel"]),
                        .camera(nil, maxFrameBytes: 0, reason: "unframed_channel")])
        XCTAssertEqual(e.frame(["type": "camera", "capture": NSNull()]), [.camera(nil, maxFrameBytes: 0, reason: nil)])
    }

    func testTheMediaAnswer() {
        XCTAssertEqual(LiveMedia.answer(nil, offered: 1), .unframed, "an old channel does not answer")
        XCTAssertEqual(LiveMedia.answer(1, offered: nil), .unframed, "not offered: not framed")
        XCTAssertEqual(LiveMedia.answer(1, offered: 1), .framed(1))
        for bad: Any in [2, 0, -1, 1.5, "1", true, NSNull()] {
            guard case .invalid = LiveMedia.answer(bad, offered: 1) else { return XCTFail("\(bad)") }
        }
    }

    func testAudioPacketsGetTheKindByte() {
        let block = Data([0, 2, 0xA, 0xB, 0, 1, 0xC])
        XCTAssertEqual(MediaFraming.audio(lengthPrefixed: block), Data([0, 3, 1, 0xA, 0xB, 0, 2, 1, 0xC]))
        XCTAssertEqual(MediaFraming.audio(lengthPrefixed: Data()), Data())
        XCTAssertNil(MediaFraming.audio(lengthPrefixed: Data([0, 3, 0xA])), "a length past the end")
        XCTAssertNil(MediaFraming.audio(lengthPrefixed: Data([0])))
    }

    // MARK: the state

    func testOnlyAStandingPhoneSeesByItself() throws {
        var i = SightInputs()
        XCTAssertEqual(i.state, .notOffered)
        i.ask = SightAsk(capture)
        XCTAssertEqual(i.state, .notOffered, "only the capture master is asked")
        i.master = true
        i.posture = .open
        XCTAssertEqual(i.state, .hint, "open in a hand the room can see but the phone does not")
        i.active = true
        i.authorized = true
        i.posture = .tent
        XCTAssertEqual(i.state, .on(camera: .outerFront))
        XCTAssertEqual(i.state.camera?.view, .facing)
        i.posture = .tabletop(camerasUp: true)
        XCTAssertEqual(i.state, .on(camera: .rear))
        XCTAssertEqual(i.state.camera?.view, .room)
        i.posture = .tabletop(camerasUp: false)
        XCTAssertEqual(i.state, .paused(.wrongHalf))
    }

    func testAClosedPhoneInAHandSeesOnRequest() throws {
        var i = SightInputs()
        i.ask = SightAsk(capture)
        i.master = true
        i.active = true
        i.authorized = true
        i.posture = .hand
        XCTAssertEqual(i.state, .off, "off until turned on")
        XCTAssertTrue(i.state.offered)
        i.handOn = true
        XCTAssertEqual(i.state, .on(camera: .outerFront), "the front by default")
        i.handCamera = .rear
        XCTAssertEqual(i.state, .on(camera: .rear))
        i.enabled = false
        XCTAssertEqual(i.state, .on(camera: .rear), "the standing switch is another switch")
        i.posture = .tent
        XCTAssertEqual(i.state, .off)
    }

    func testPermissionPausesAndFailures() throws {
        var i = SightInputs()
        i.ask = SightAsk(capture)
        i.master = true
        i.posture = .tent
        XCTAssertEqual(i.state, .paused(.background))
        i.active = true
        XCTAssertEqual(i.state, .asking, "not asked yet: the controller shows the prompt")
        i.prompting = true
        i.active = false
        XCTAssertEqual(i.state, .asking, "the prompt makes the app inactive; that is not the background")
        i.posture = .open
        XCTAssertEqual(i.state, .asking, "no posture decline while the prompt is up")
        i.posture = .tent
        i.prompting = false
        i.active = true
        i.authorized = false
        XCTAssertEqual(i.state, .denied)
        i.authorized = true
        i.enabled = false
        XCTAssertEqual(i.state, .off)
        i.enabled = true
        i.taken = true
        XCTAssertEqual(i.state, .paused(.taken))
        i.taken = false
        i.pressure = true
        XCTAssertEqual(i.state, .paused(.hot), "the system stopped the camera under pressure")
        i.pressure = false
        i.thermal = .serious
        XCTAssertEqual(i.state, .on(camera: .outerFront), "warm: still video, at a lower rate")
        i.thermal = .critical
        XCTAssertEqual(i.state, .paused(.hot))
        i.thermal = .normal
        i.failure = SightStartFailure(camera: .rear, failure: .noCamera)
        XCTAssertEqual(i.state, .on(camera: .outerFront), "a failure holds for its camera only")
        i.failure = SightStartFailure(camera: .outerFront, failure: .noFormat)
        XCTAssertEqual(i.state, .failed(.noFormat))
        XCTAssertTrue(i.state.offered)
    }

    func testARefusalShowsUntilTheNextAsk() throws {
        var i = SightInputs()
        i.master = true
        i.refused = "nonconforming"
        XCTAssertEqual(i.state, .refused("nonconforming"))
        XCTAssertFalse(i.state.offered)
        XCTAssertNil(i.state.declineReason, "the channel declined already")
    }

    func testDeclineReasons() {
        let cases: [(SightState, String?)] = [
            (.notOffered, nil), (.asking, nil), (.on(camera: .rear), nil), (.refused("x"), nil),
            (.hint, "posture"), (.paused(.wrongHalf), "posture"), (.off, "user_off"),
            (.paused(.background), "background"), (.paused(.taken), "camera_taken"), (.paused(.hot), "thermal"),
            (.denied, "camera_denied"), (.failed(.noH264), "no_h264"), (.failed(.noCamera), "no_camera"),
            (.failed(.noFormat), "no_format"), (.failed(.cameraTaken), "camera_taken"),
            (.failed(.encoderFailed), "encoder_failed"),
        ]
        for (s, r) in cases { XCTAssertEqual(s.declineReason, r, "\(s)") }
        // Only a held camera and a failed encoder are tried again without a new ask.
        XCTAssertEqual([SightFailure.noH264, .noCamera, .noFormat, .cameraTaken, .encoderFailed].map(\.retried),
                       [false, false, false, true, true])
    }

    func testOneDeclinePerReasonUntilVideoResumes() {
        var d = SightDeclines()
        XCTAssertEqual(d.reason(for: .paused(.background)), "background")
        XCTAssertNil(d.reason(for: .paused(.background)), "not repeated")
        XCTAssertNil(d.reason(for: .asking), "none while the prompt is up")
        XCTAssertNil(d.reason(for: .paused(.background)), "the prompt keeps the last reason")
        XCTAssertEqual(d.reason(for: .denied), "camera_denied", "a new reason")
        XCTAssertNil(d.reason(for: .on(camera: .outerFront)))
        XCTAssertNil(d.reason(for: .denied), "the camera started, but no key frame left: not resumed")
        d.resumed()
        XCTAssertEqual(d.reason(for: .denied), "camera_denied", "video resumed in between")
    }

    // MARK: the uplink

    private func bytes(_ d: Data, _ r: Range<Int>) -> [UInt8] { [UInt8](d[r]) }

    private func block(_ d: Data, at offset: Int) throws -> (object: [String: Any], end: Int) {
        let n = Int(d[offset]) | Int(d[offset + 1]) << 8
        let json = d[(offset + 2)..<(offset + 2 + n)]
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any]), offset + 2 + n)
    }

    func testAKeyFrameCarriesBothConfigs() throws {
        var u = SightUplink()
        let payload = Data([0, 0, 0, 1, 0x67, 0x42])
        let rate = SightRate(fps: 25, bitrate: 1_200_000)
        let f = try XCTUnwrap(u.video(key: true, at: 0x0102_0304_0506, payload: payload, width: 1280, height: 720,
                                      view: .facing, rate: rate, maxFrameBytes: 1 << 20))
        XCTAssertEqual(f[0], 0x02, "the video kind")
        XCTAssertEqual(f[1], 0x03, "key, with a rate config")
        XCTAssertEqual(bytes(f, 2..<6), [0, 0, 0, 0], "seq 0, little-endian")
        XCTAssertEqual(bytes(f, 6..<14), [6, 5, 4, 3, 2, 1, 0, 0], "at, little-endian")
        let config = try block(f, at: 14)
        XCTAssertEqual(config.object["width"] as? Int, 1280)
        XCTAssertEqual(config.object["height"] as? Int, 720)
        XCTAssertEqual(config.object["view"] as? String, "facing")
        XCTAssertNil(config.object["codec"], "no codec: it only echoed the ask")
        let rateBlock = try block(f, at: config.end)
        XCTAssertEqual(rateBlock.object["fps"] as? Int, 25)
        XCTAssertEqual(rateBlock.object["bitrate"] as? Int, 1_200_000)
        XCTAssertEqual(f[rateBlock.end...], payload[...])
    }

    func testDeltaFramesCarryTheRateOnlyWhenItChanges() throws {
        var u = SightUplink()
        let rate = SightRate(fps: 25, bitrate: 1_200_000)
        _ = u.video(key: true, at: 100, payload: Data([1]), width: 1280, height: 720, view: .room, rate: rate,
                    maxFrameBytes: 1 << 20)
        let d = try XCTUnwrap(u.video(key: false, at: 140, payload: Data([2]), width: 1280, height: 720, view: .room,
                                      rate: rate, maxFrameBytes: 1 << 20))
        XCTAssertEqual(d.count, 15, "a 14-byte header, then the payload")
        XCTAssertEqual(d[1], 0)
        XCTAssertEqual(bytes(d, 2..<6), [1, 0, 0, 0])
        let slow = SightRate(fps: 2, bitrate: 96000)
        let r = try XCTUnwrap(u.video(key: false, at: 180, payload: Data([3]), width: 1280, height: 720, view: .room,
                                      rate: slow, maxFrameBytes: 1 << 20))
        XCTAssertEqual(r[1], 0x02, "a rate change rides a delta frame, no key frame")
        XCTAssertEqual(try block(r, at: 14).object["fps"] as? Int, 2)
        let next = try XCTUnwrap(u.video(key: false, at: 680, payload: Data([4]), width: 1280, height: 720,
                                         view: .room, rate: slow, maxFrameBytes: 1 << 20))
        XCTAssertEqual(next[1], 0, "told once")
    }

    func testADroppedChunkLeavesAGapAndWaitsForAKeyFrame() throws {
        var u = SightUplink()
        let rate = SightRate(fps: 25, bitrate: 1_200_000)
        _ = u.video(key: true, at: 0, payload: Data([1]), width: 1280, height: 720, view: .facing, rate: rate,
                    maxFrameBytes: 200)
        XCTAssertNil(u.video(key: false, at: 40, payload: Data(count: 300), width: 1280, height: 720, view: .facing,
                             rate: rate, maxFrameBytes: 200), "too large")
        XCTAssertTrue(u.needsKey)
        XCTAssertNil(u.video(key: false, at: 80, payload: Data([2]), width: 1280, height: 720, view: .facing,
                             rate: rate, maxFrameBytes: 200), "no delta before the key frame")
        let k = try XCTUnwrap(u.video(key: true, at: 120, payload: Data([3]), width: 1280, height: 720, view: .facing,
                                      rate: rate, maxFrameBytes: 200))
        XCTAssertEqual(bytes(k, 2..<6), [3, 0, 0, 0], "the unsent chunks still count")
        XCTAssertFalse(u.needsKey)
    }

    func testANewEncoderStartsWithAKeyFrame() throws {
        var u = SightUplink()
        let rate = SightRate(fps: 25, bitrate: 1_200_000)
        _ = u.video(key: true, at: 0, payload: Data([1]), width: 1280, height: 720, view: .facing, rate: rate,
                    maxFrameBytes: 1 << 20)
        u.expectKey()
        XCTAssertNil(u.video(key: false, at: 40, payload: Data([2]), width: 720, height: 1280, view: .facing, rate: rate,
                             maxFrameBytes: 1 << 20), "a new encoder's delta never joins the old chain")
        XCTAssertNotNil(u.video(key: true, at: 80, payload: Data([3]), width: 720, height: 1280, view: .facing,
                                rate: rate, maxFrameBytes: 1 << 20))
    }

    func testSeqWrapsAndTheClockOnlyMovesForward() throws {
        var u = SightUplink(seq: .max)
        let rate = SightRate(fps: 25, bitrate: 1_200_000)
        let a = try XCTUnwrap(u.video(key: true, at: 1000, payload: Data([1]), width: 720, height: 1280, view: .room,
                                      rate: rate, maxFrameBytes: 1 << 20))
        XCTAssertEqual(bytes(a, 2..<6), [0xFF, 0xFF, 0xFF, 0xFF])
        // A new run re-anchors its clock behind the last stamp sent.
        let b = try XCTUnwrap(u.video(key: true, at: 990, payload: Data([2]), width: 1280, height: 720, view: .facing,
                                      rate: rate, maxFrameBytes: 1 << 20))
        XCTAssertEqual(bytes(b, 2..<6), [0, 0, 0, 0], "wraps to 0")
        XCTAssertEqual(bytes(b, 6..<14), [0xE9, 3, 0, 0, 0, 0, 0, 0], "at least the last at plus one: 1001")
    }

    // MARK: kept

    func testPostureFromTheLayoutAndTheHinge() {
        XCTAssertEqual(SightPosture.from(layout: .tent, halfOpen: true), .tent)
        XCTAssertEqual(SightPosture.from(layout: .tent, halfOpen: false), .hand, "the closed phone held sideways")
        XCTAssertEqual(SightPosture.from(layout: .tent, halfOpen: false, charging: true), .tent, "closed on a charging stand")
        XCTAssertEqual(SightPosture.from(layout: .phone, halfOpen: false, charging: true), .hand, "upright on a charger")
        XCTAssertEqual(SightPosture.from(layout: .tabletop(top: 400, gap: 20), halfOpen: true), .tabletop(camerasUp: true))
        XCTAssertEqual(SightPosture.from(layout: .stacked(top: 400, gap: 0), halfOpen: false), .open)
        XCTAssertEqual(SightPosture.from(layout: .side, halfOpen: true), .open, "a book held open is in a hand")
        XCTAssertEqual(SightPosture.from(layout: .phone, halfOpen: false), .hand)
    }

    func testClockAnchorsOnceAndFollowsTheFrames() {
        var c = SightClock()
        // The first frame was captured 30 ms before now.
        XCTAssertEqual(c.at(frameS: 100.0, nowWallMs: 1_000_000, nowFrameS: 100.03), 999_970)
        // Later frames follow the capture clock, whatever the wall clock reads now.
        XCTAssertEqual(c.at(frameS: 100.04, nowWallMs: 5_000_000, nowFrameS: 100.05), 1_000_010)
    }

    func testAnnexB() throws {
        let avcc = Data([0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
        let out = try XCTUnwrap(AnnexB.from(avcc: avcc, parameterSets: [Data([0x67, 1]), Data([0x68, 2])]))
        XCTAssertEqual([UInt8](out), [0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
        XCTAssertNil(AnnexB.from(avcc: Data([0, 0, 0, 9, 1])), "a length past the end")
    }
}
