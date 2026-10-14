// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class AmbientEdgeTests: XCTestCase {
    private func sends(_ a: [AmbientEdge.Action]) -> [[String: AnyHashable]] {
        a.compactMap { if case .send(let f) = $0 { f } else { nil } }
    }

    private func types(_ a: [AmbientEdge.Action]) -> [String] { sends(a).compactMap { $0["type"] as? String } }

    /// An edge with ambient on: it said `hello`, so it reports playback (live mode).
    private func seated() -> AmbientEdge {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        _ = e.frame(["type": "meta", "conn": "c1"])
        _ = e.packetEncoded()
        return e
    }

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
    }

    func testBinaryBeforeSpeechIsDropped() {
        var e = AmbientEdge()
        guard case .warn = e.binary(Data([1])).first else { return XCTFail() }
    }

    func testPlayedIsAWatermarkThrottledAndFlushedAtDrain() {
        var e = seated()
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
        var e = seated()
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
        var e = seated()
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

    /// A press stops what is playing at once, fillers too, and reports it `interrupted`.
    func testPressStopsPlaybackAndReportsTheSpeech() {
        var e = AmbientEdge(room: "r")
        e.socketOpened()
        _ = e.frame(["type": "meta", "conn": "c1"])
        _ = e.packetEncoded()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        let a = e.pressBegan()
        XCTAssertEqual(a, [.send(["type": "mute", "on": false]), .clearPlayback, .resetDecoder,
                           .send(["type": "interrupted", "speech_id": "c-1"])])
        XCTAssertFalse(e.speaking)
        // The cut block's completion is stale: no played for it.
        XCTAssertTrue(e.played(gen: g, ms: 40).isEmpty)
        // Nothing playing: a press reports nothing.
        _ = e.pressEnded()
        XCTAssertEqual(types(e.pressBegan()), ["mute"])
    }

    /// While a press is held every speech that arrives is dropped and reported; its audio is
    /// discarded without a warning. After the press, speech plays again.
    func testSpeechDuringAPressIsDroppedAndReported() {
        var e = seated()
        _ = e.pressBegan()
        let a = e.frame(["type": "speech", "speech_id": "s4"])
        XCTAssertEqual(sends(a), [["type": "interrupted", "speech_id": "s4"]])
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
        XCTAssertEqual(sends(e.frame(["type": "speech", "speech_id": "c-5"])), [["type": "interrupted", "speech_id": "c-5"]])
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
        XCTAssertFalse(e.speaking)
        _ = e.pressEnded()
        // The dropped speech's late audio stays dropped; the next speech plays.
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
        XCTAssertEqual(e.frame(["type": "speech", "speech_id": "c-6"]), [.resetDecoder])
        guard case .play = e.binary(Data([1])).first else { return XCTFail() }
    }

    // MARK: message mode (ambient off) and read aloud

    /// A declaration stops nothing: the decoder keeps its state and audio already received plays
    /// first, so speeches play in the order they were declared.
    func testDeclarationDoesNotCutAudioAlreadyReceived() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g1) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g1)
        // A new Opus stream: the decoder is reset, nothing buffered is cleared.
        XCTAssertEqual(e.frame(["type": "speech", "speech_id": "c-2"]), [.resetDecoder])
        guard case .play(_, let g2) = e.binary(Data([2])).first else { return XCTFail() }
        XCTAssertNotEqual(g1, g2)
        XCTAssertEqual(e.current, "c-2")
    }

    /// `stop_audio` for the current speech, or naming none, clears every buffered speech.
    func testStopAudioClearsEveryBufferedSpeech() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        _ = e.binary(Data([1]))
        _ = e.frame(["type": "speech", "speech_id": "c-2"])
        _ = e.binary(Data([2]))
        // A stop for the earlier id is stale.
        XCTAssertTrue(e.frame(["type": "stop_audio", "speech_id": "c-1"]).isEmpty)
        XCTAssertEqual(e.frame(["type": "stop_audio", "speech_id": "c-2"]), [.clearPlayback, .resetDecoder])
        _ = e.frame(["type": "speech", "speech_id": "c-3"])
        XCTAssertEqual(e.frame(["type": "stop_audio"]), [.clearPlayback, .resetDecoder])
        // With nothing current, a stop naming a speech is stale; one naming none still clears.
        XCTAssertTrue(e.frame(["type": "stop_audio", "speech_id": "c-3"]).isEmpty)
        XCTAssertEqual(e.frame(["type": "stop_audio"]), [.clearPlayback, .resetDecoder])
    }

    /// Ambient off: the channel takes no playback report, so none is sent.
    func testMessageModeSendsNoReports() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        XCTAssertTrue(e.played(gen: g, ms: 300).isEmpty)
        _ = e.frame(["type": "speech", "speech_id": "c-2"])
        guard case .play(_, let g2) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g2)
        // A press stops and drops locally, and says nothing.
        XCTAssertEqual(e.pressBegan(), [.clearPlayback, .resetDecoder])
        XCTAssertEqual(e.frame(["type": "speech", "speech_id": "c-3"]), [.clearPlayback, .resetDecoder])
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
    }

    /// A read stops the reply that plays and, with ambient on, reports it; the reply's late audio
    /// is discarded quietly.
    func testReadStopsTheReplyAndReportsItWithAmbientOn() {
        var e = seated()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        XCTAssertEqual(e.readBegan(), [.clearPlayback, .resetDecoder, .send(["type": "interrupted", "speech_id": "c-1"])])
        XCTAssertTrue(e.reading)
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
        XCTAssertTrue(e.played(gen: g, ms: 40).isEmpty)
        // A stop_audio for the stopped reply does not touch the read.
        XCTAssertTrue(e.frame(["type": "stop_audio", "speech_id": "c-1"]).isEmpty)
        XCTAssertTrue(e.frame(["type": "stop_audio"]).isEmpty)
        // Neither does the socket closing.
        XCTAssertTrue(e.socketClosed().isEmpty)
        XCTAssertTrue(e.reading)
    }

    /// A read started before the reply's first packet still reports it: the channel waits for
    /// that speech, and its packets will be dropped.
    func testReadBeforeTheFirstPacketReportsTheReply() {
        var e = seated()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        XCTAssertEqual(e.readBegan(), [.clearPlayback, .resetDecoder, .send(["type": "interrupted", "speech_id": "c-1"])])
        XCTAssertTrue(e.binary(Data([1])).isEmpty)
    }

    func testReadWithAmbientOffReportsNothing() {
        var e = AmbientEdge()
        _ = e.frame(["type": "speech", "speech_id": "c-1"])
        guard case .play(_, let g) = e.binary(Data([1])).first else { return XCTFail() }
        e.scheduled(gen: g)
        XCTAssertEqual(e.readBegan(), [.clearPlayback, .resetDecoder])
        // Nothing playing: a second read only stops the first.
        XCTAssertEqual(e.readBegan(), [.stopRead, .clearPlayback])
        e.readEnded()
        XCTAssertFalse(e.reading)
    }

    /// The live exchange goes first: a declaration or a press stops a local read.
    func testDeclarationAndPressStopTheRead() {
        var e = AmbientEdge()
        _ = e.readBegan()
        XCTAssertEqual(e.frame(["type": "speech", "speech_id": "c-1"]), [.stopRead, .clearPlayback, .resetDecoder])
        XCTAssertFalse(e.reading)
        guard case .play = e.binary(Data([1])).first else { return XCTFail() }

        var p = seated()
        _ = p.readBegan()
        XCTAssertEqual(p.pressBegan(), [.send(["type": "mute", "on": false]), .stopRead, .clearPlayback])
        XCTAssertFalse(p.reading)

        var h = AmbientEdge()
        _ = h.readBegan()
        XCTAssertEqual(h.hush().first, .stopRead)
    }
}
