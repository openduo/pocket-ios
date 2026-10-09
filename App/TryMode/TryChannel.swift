// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import CryptoKit
import Foundation
import PocketCore
import PocketOpus

/// The channel 先体验 talks to, inside the app. It answers the HTTP calls, the display socket and
/// the ambient edge socket the way the ambient channel does (the same paths, bodies and frames as
/// `Tools/mock-channel`), with `TryScript` as the brain. Uploads and the room log stay in memory.
final class TryChannel: @unchecked Sendable {
    static let shared = TryChannel()

    private let queue = DispatchQueue(label: "pocket.try")
    private var log: [ImlogEntry] = []
    private var files: [String: (data: Data, mime: String)] = [:]
    private var voiceResults: [String: Data] = [:]
    private var next = 0
    private var seq = 0
    private var greeted = false
    private weak var display: DisplaySocket?
    private weak var edge: EdgeSocket?
    private var edgeListening = false

    /// Pacing of a scripted turn, so the thinking and tool steps can be seen. Display only:
    /// a real turn's timing comes from the brain.
    private static let stepDelay: TimeInterval = 0.9

    func reset() {
        queue.sync {
            log = []
            files = [:]
            voiceResults = [:]
            next = 0
            seq = 0
            greeted = false
            edgeListening = false
        }
    }

    // MARK: HTTP

    func request(method: String, path: String, headers: [String: String], body: Data) -> (status: Int, body: Data) {
        queue.sync { handle(method: method, path: path, headers: headers, body: body) }
    }

    private func handle(method: String, path: String, headers: [String: String], body: Data) -> (status: Int, body: Data) {
        let comps = URLComponents(string: path)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
        switch (method, comps?.path ?? path) {
        case ("GET", "/healthz"):
            return json(200, ["ok": true])
        case ("GET", "/api/state"):
            // No `limits`: uploads have no bound here (they stay in memory until exit).
            return json(200, ["room": TryMode.room, "room_name": roomName, "date": DayString.local(Date()),
                              "daemon_ok": true, "cerebellum_ok": true, "imlog": encode(log)])
        case ("GET", "/api/imlog"):
            let date = query["date"] ?? ""
            let rows = log.filter { e in ThreadBuilder.parse(e.at).map { DayString.local($0) == date } ?? false }
            return json(200, ["room": TryMode.room, "date": date, "entries": encode(rows)])
        case ("POST", "/api/inject"):
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let text = o["text"] as? String ?? ""
            let atts = ((o["attachments"] as? [[String: Any]]) ?? []).map {
                ChannelAttachment(name: $0["name"] as? String ?? "", mime: $0["mime"] as? String ?? "",
                                  sha256: $0["sha256"] as? String)
            }
            let utt = newUtt()
            let at = now()
            append(ImlogEntry(at: at, kind: "typed", text: text, utt_id: utt, attachments: atts.isEmpty ? nil : atts))
            answer(utt: utt)
            return json(200, ["utt_id": utt, "at": at, "record_available": true])
        case ("POST", "/api/upload"):
            let name = query["name"] ?? "file"
            let mime = headers["Content-Type"] ?? "application/octet-stream"
            let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            files[sha] = (body, mime)
            return json(200, ["name": name, "mime": mime, "sha256": sha, "path": "try/\(sha)"])
        case ("GET", "/api/attachment"):
            guard let sha = query["sha256"], let f = files[sha] else { return json(404, ["error": "not_found"]) }
            return (200, f.data)
        case ("POST", "/api/voice"):
            return voice(headers: headers, body: body)
        default:
            return json(404, ["error": "not_found"])
        }
    }

    private var roomName: String { TryScript.en ? "Try it" : "体验" }

    /// A voice note (`/api/voice`): length-prefixed Opus packets. The same id gets the first
    /// result again, as the channel does for a retry.
    private func voice(headers: [String: String], body: Data) -> (status: Int, body: Data) {
        let id = headers["X-Voice-Id"] ?? ""
        if let prev = voiceResults[id] { return (200, prev) }
        var packets = 0, off = 0
        let bytes = [UInt8](body)
        while off + 2 <= bytes.count {
            off += 2 + (Int(bytes[off]) | Int(bytes[off + 1]) << 8)
            packets += 1
        }
        guard packets > 0, off == bytes.count else { return json(packets == 0 ? 422 : 400, ["voice_id": id, "error": "bad_body"]) }
        let seconds = Double(packets * PocketConstants.frameMs) / 1000
        let text = TryScript.voiceText(seconds: seconds)
        let utt = newUtt()
        let res = (try? JSONSerialization.data(withJSONObject: ["voice_id": id, "text": text, "utt_id": utt])) ?? Data()
        voiceResults[id] = res
        append(ImlogEntry(at: now(), kind: "typed", text: text, utt_id: utt, voice_source: headers["X-Voice-Source"]))
        answer(utt: utt)
        return (200, res)
    }

    // MARK: the brain

    /// Plays the next scripted turn on the display socket: received, thinking, each tool call and
    /// result, the answer, any file, idle. Spoken on the edge when ambient mode holds the seat.
    private func answer(utt: String) {
        let turns = TryScript.turns
        let turn = turns[next]
        next = next + 1 < turns.count ? next + 1 : min(1, turns.count - 1)
        var t: TimeInterval = 0
        func at(_ dt: TimeInterval, _ f: @escaping () -> Void) {
            t += dt
            queue.asyncAfter(deadline: .now() + t, execute: f)
        }
        frame(["type": "turn", "utt_id": utt, "phase": "received"])
        at(Self.stepDelay) { self.frame(["type": "turn", "utt_id": utt, "phase": "thinking"]) }
        for tool in turn.tools {
            let input = String(decoding: (try? JSONSerialization.data(withJSONObject: tool.input)) ?? Data(), as: UTF8.self)
            at(Self.stepDelay) { self.frame(["type": "turn", "utt_id": utt, "phase": "tool", "label": tool.name, "input_summary": input]) }
            at(Self.stepDelay) { self.frame(["type": "turn", "utt_id": utt, "phase": "tool", "label": tool.name + ToolLine.resultSuffix]) }
        }
        let speech = "c-" + utt
        at(Self.stepDelay) {
            let spoke = self.speak(id: speech, audio: turn.audio)
            self.append(ImlogEntry(at: self.now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: turn.text,
                                   utt_id: utt, unspoken: !spoke))
            self.frame(["type": "answer_final", "speech_id": speech, "utt_id": utt, "text": turn.text])
            if let f = turn.file, let url = Bundle.main.url(forResource: f.resource, withExtension: "md"),
               let data = try? Data(contentsOf: url) {
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                self.files[sha] = (data, f.mime)
                self.append(ImlogEntry(at: self.now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: "",
                                       attachments: [ChannelAttachment(name: f.name, mime: f.mime, sha256: sha)], unspoken: true))
            }
            self.frame(["type": "turn", "utt_id": utt, "phase": "idle"])
        }
    }

    private func append(_ e: ImlogEntry) {
        log.append(e)
        frame(["type": "imlog_append", "entries": encode([e])])
    }

    private func newUtt() -> String {
        seq += 1
        return "try-\(seq)"
    }

    private func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func encode(_ rows: [ImlogEntry]) -> [[String: Any]] {
        rows.compactMap { e in
            (try? JSONEncoder().encode(e)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private func json(_ status: Int, _ o: [String: Any]) -> (status: Int, body: Data) {
        (status, (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
    }

    // MARK: display socket

    func openDisplay(_ s: DisplaySocket) { queue.sync { display = s } }
    func closeDisplay(_ s: DisplaySocket) { queue.sync { if display === s { display = nil } } }
    func displayOpen(_ s: DisplaySocket) -> Bool { queue.sync { display === s } }

    private func frame(_ f: [String: Any]) {
        display?.onFrame?(f)
    }

    // MARK: edge socket

    func openEdge(_ s: EdgeSocket) {
        queue.async { [self] in
            edge = s
            edgeListening = false
            edgeText(["type": "meta", "conn": "try-edge"])
            edgeText(["type": "audio_params", "rate": AmbientEdge.rate])
        }
    }

    func closeEdge(_ s: EdgeSocket) { queue.sync { if edge === s { edge = nil; edgeListening = false } } }
    func edgeOpen(_ s: EdgeSocket) -> Bool { queue.sync { edge === s } }

    /// A text frame from the app's edge.
    func edgeReceived(_ f: [String: Any]) {
        queue.async { [self] in
            switch f["type"] as? String {
            case "hello":
                edgeListening = true
                edgeText(["type": "meta", "role": AmbientEdge.Role.master.rawValue, "state": "listening"])
                if !greeted {
                    greeted = true
                    let hello = TryScript.ambientHello
                    let spoke = speak(id: "c-try-hello", audio: hello.audio)
                    append(ImlogEntry(at: now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: hello.text,
                                      unspoken: !spoke))
                }
            case "hush":
                edgeText(["type": "stop_audio"])
            default:
                break
            }
        }
    }

    private func edgeText(_ f: [String: Any]) {
        guard let edge, let d = try? JSONSerialization.data(withJSONObject: f) else { return }
        edge.onText?(String(decoding: d, as: UTF8.self))
    }

    /// Declares the speech and sends the bundled clip as 20 ms Opus packets, as the channel does
    /// for TTS. Only when ambient mode is listening; a typed chat is not read aloud.
    /// Returns whether it was spoken.
    @discardableResult
    private func speak(id: String, audio: String) -> Bool {
        guard edgeListening, let edge, let packets = Self.packets(audio) else { return false }
        edgeText(["type": "speech", "speech_id": id])
        for p in packets { edge.onBinary?(p) }
        return true
    }

    /// The bundled clip decoded to 16 kHz mono and encoded with the app's own Opus encoder.
    private static func packets(_ name: String) -> [Data]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
              let file = try? AVAudioFile(forReading: url),
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PocketConstants.sampleRate),
                                      channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: file.processingFormat, to: out),
              let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: src)) != nil else { return nil }
        let ratio = out.sampleRate / file.processingFormat.sampleRate
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1)
        else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        guard err == nil, let ch = dst.int16ChannelData, let enc = try? OpusVoiceEncoder() else { return nil }
        var samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(dst.frameLength)))
        // Pad to whole frames so the tail is not dropped.
        let r = samples.count % PocketConstants.frameSamples
        if r > 0 { samples += Array(repeating: 0, count: PocketConstants.frameSamples - r) }
        return try? enc.push(samples)
    }
}
