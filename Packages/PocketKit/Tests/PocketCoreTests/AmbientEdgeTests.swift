// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class AmbientEdgeTests: XCTestCase {
    private func sends(_ a: [AmbientEdge.Action]) -> [[String: AnyHashable]] {
        a.compactMap { if case .send(let f) = $0 { f } else { nil } }
    }

    private func types(_ a: [AmbientEdge.Action]) -> [String] { sends(a).compactMap { $0["type"] as? String } }

    func testHelloWaitsForTheFirstPacketAndTheConn() {
        var e = AmbientEdge(room: "study")
        e.aec = true
        e.socketOpened()
        // The socket says who we are, but nothing is captured yet: no hello.
        XCTAssertTrue(e.frame(["type": "meta", "conn": "c7"]).isEmpty)
        XCTAssertFalse(e.sendsAudio)
        let a = e.packetEncoded()
        XCTAssertEqual(sends(a).first, ["type": "hello", "room": "study", "conn": "c7", "edge": "client", "aec": true])
        // The room's mic switch is restated with every hello: `on` means the mic is on.
        XCTAssertEqual(sends(a).last, ["type": "mute", "on": true])
        XCTAssertTrue(e.sendsAudio)
        // A second packet sends nothing new.
        XCTAssertTrue(e.packetEncoded().isEmpty)
    }

    func testPacketBeforeConnHellosWhenConnArrives() {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        XCTAssertTrue(e.packetEncoded().isEmpty)
        XCTAssertEqual(types(e.frame(["type": "meta", "conn": "c1"])), ["hello", "mute"])
    }

    func testReconnectReclaimsTheSeat() {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        _ = e.frame(["type": "meta", "conn": "c1"])
        _ = e.packetEncoded()
        _ = e.socketClosed()
        XCTAssertFalse(e.sendsAudio)
        e.socketOpened()
        let a = e.frame(["type": "meta", "conn": "c2"])
        XCTAssertEqual(sends(a).first?["conn"], "c2")
    }

    func testPeerStopsAudioUntilTakeover() {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        _ = e.frame(["type": "meta", "conn": "c1"])
        _ = e.packetEncoded()
        _ = e.frame(["type": "meta", "role": "peer"])
        XCTAssertFalse(e.sendsAudio)
        XCTAssertEqual(types(e.takeover()), ["hello", "mute"])
        _ = e.frame(["type": "meta", "role": "master"])
        XCTAssertTrue(e.sendsAudio)
    }

    func testUserMuteStopsBytesAndPressMuteDoesNot() {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        _ = e.frame(["type": "meta", "conn": "c1"])
        _ = e.packetEncoded()
        // A press switches the room mic off but audio keeps flowing (the channel drops it, the
        // lease holds).
        XCTAssertEqual(sends(e.pressBegan()), [["type": "mute", "on": false]])
        XCTAssertTrue(e.sendsAudio)
        // A Passport press during a phone hold: no second frame.
        XCTAssertTrue(e.pressBegan().isEmpty)
        XCTAssertTrue(e.pressEnded().isEmpty)
        XCTAssertEqual(sends(e.pressEnded()), [["type": "mute", "on": true]])
        // An unmatched end does nothing.
        XCTAssertTrue(e.pressEnded().isEmpty)
        // The user's mute: frame and no bytes.
        XCTAssertEqual(sends(e.setUserMute(true)), [["type": "mute", "on": false]])
        XCTAssertFalse(e.sendsAudio)
        // A press while muted changes nothing on the wire, and its end keeps the mute.
        XCTAssertTrue(e.pressBegan().isEmpty)
        XCTAssertTrue(e.pressEnded().isEmpty)
        XCTAssertEqual(sends(e.setUserMute(false)), [["type": "mute", "on": true]])
    }

    func testBinaryBeforeSpeechIsDropped() {
        var e = AmbientEdge()
        guard case .warn = e.binary(Data([1])).first else { return XCTFail() }
    }

    func testPlayedIsAWatermarkThrottledAndFlushedAtDrain() {
        var e = AmbientEdge()
        XCTAssertEqual(e.frame(["type": "speech", "speech_id": "c-1"]), [.resetDecoder])
        var gens: [Int] = []
        for _ in 0..<20 {
            guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
            e.scheduled(gen: g)
            gens.append(g)
        }
        XCTAssertTrue(e.speaking)
        var reports: [Int] = []
        for g in gens {
            for f in sends(e.played(gen: g, ms: 60)) { reports.append(f["ms"] as! Int) }
        }
        // First block reports at once, then every >= 250 ms, then the drain flushes 1200.
        XCTAssertEqual(reports, [60, 360, 660, 960, 1200])
        XCTAssertFalse(e.speaking)
    }

    func testStopAudioCutsAnswersButNotFillers() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "s12"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        // A filler plays out and keeps reporting.
        XCTAssertTrue(e.frame(["type": "stop_audio", "reason": "barge_in"]).isEmpty)
        XCTAssertEqual(types(e.played(gen: g, ms: 40)), ["played"])

        _ = e.frame(["type": "speech", "speech_id": "c-2"])
        guard case .play(_, let g2) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g2)
        // A stop for another id is ignored.
        XCTAssertTrue(e.frame(["type": "stop_audio", "speech_id": "c-9", "reason": "barge_in"]).isEmpty)
        XCTAssertEqual(e.frame(["type": "stop_audio", "speech_id": "c-2", "reason": "barge_in"]), [.clearPlayback, .resetDecoder])
        // The cut block's completion is a stale generation: no played after the stop.
        XCTAssertTrue(e.played(gen: g2, ms: 60).isEmpty)
        XCTAssertFalse(e.speaking)
        // And binary frames after the stop have no owner.
        guard case .warn = e.binary(Data([1])).first else { return XCTFail() }
    }

    func testOldSpeechTailIsNotCreditedToTheNext() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g1) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g1)
        _ = e.frame(["type": "speech", "speech_id": "c-2"])
        XCTAssertTrue(e.played(gen: g1, ms: 500).isEmpty)
        guard case .play(_, let g2) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g2)
        XCTAssertEqual(sends(e.played(gen: g2, ms: 20)), [["type": "played", "speech_id": "c-2", "ms": 20]])
    }

    func testLocalHushStopsFillersAndSendsHush() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "s3"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        let a = e.hush()
        XCTAssertEqual(a, [.clearPlayback, .resetDecoder, .send(["type": "hush"])])
        XCTAssertTrue(e.played(gen: g, ms: 20).isEmpty)
    }

    func testWrongRateIsFatal() {
        var e = AmbientEdge()
        guard case .fatal = e.frame(["type": "audio_params", "rate": 24000, "frame_ms": 120]).first else { return XCTFail() }
        XCTAssertTrue(e.frame(["type": "audio_params", "rate": 16000, "frame_ms": 120]).isEmpty)
    }

    func testSocketCloseStopsPlayback() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        XCTAssertEqual(e.socketClosed(), [.clearPlayback, .resetDecoder])
        XCTAssertFalse(e.speaking)
    }
}
