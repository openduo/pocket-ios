// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import CryptoKit
import Foundation
import PocketCore
import PocketOpus

/// The channel 先体验 talks to, inside the app. It answers the HTTP calls and the `/live` socket
/// the way the ambient channel does (the same paths, bodies and frames as `Tools/mock-channel`),
/// with `TryScript` as the brain. Uploads and the room log stay in memory.
final class TryChannel: @unchecked Sendable {
    static let shared = TryChannel()

    private let queue = DispatchQueue(label: "pocket.try")
    private var log: [ImlogEntry] = []
    private var files: [String: (data: Data, mime: String)] = [:]
    /// First 202 body per `Idempotency-Key`: a repeated key gets it again.
    private var receipts: [String: Data] = [:]
    private var next = 0
    private var lastSeq = 0
    private var greeted = false
    private weak var live: LiveSocket?
    /// The app said `hello` on the socket: it holds the seat.
    private var listening = false
    /// The socket was opened with `audio=1`: it is a mouth, with or without the seat.
    private var audio = false

    /// Pacing of a scripted turn, so the thinking and tool steps can be seen. Display only:
    /// a real turn's timing comes from the brain.
    private static let stepDelay: TimeInterval = 0.9

    func reset() {
        queue.sync {
            log = []
            files = [:]
            receipts = [:]
            next = 0
            lastSeq = 0
            greeted = false
            listening = false
            audio = false
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
                              "daemon_ok": true, "cerebellum_ok": true])
        case ("GET", "/api/imlog"):
            if let since = query["since"].flatMap(Int.init) {
                return json(200, ["room": TryMode.room, "entries": encode(log.filter { ($0.seq ?? 0) > since }), "seq": lastSeq])
            }
            let date = query["date"] ?? ""
            let rows = log.filter { e in ThreadBuilder.parse(e.at).map { DayString.local($0) == date } ?? false }
            return json(200, ["room": TryMode.room, "date": date, "entries": encode(rows)])
        case ("POST", "/api/messages"):
            return message(headers: headers, body: body)
        case ("POST", "/api/speech"):
            return readAloud(body)
        case ("POST", "/api/upload"):
            let name = query["name"] ?? "file"
            let mime = headers["Content-Type"] ?? "application/octet-stream"
            let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            files[sha] = (body, mime)
            return json(200, ["name": name, "mime": mime, "sha256": sha, "path": "try/\(sha)"])
        case ("GET", "/api/attachment"):
            guard let sha = query["sha256"], let f = files[sha] else { return json(404, ["error": "not_found"]) }
            return (200, f.data)
        default:
            return json(404, ["error": "not_found"])
        }
    }

    private var roomName: String { TryScript.en ? "Try it" : "体验" }

    /// `POST /api/speech`: the scripted answer's bundled clip, in the voice message framing. A
    /// text with no clip has nothing here to synthesize it.
    private func readAloud(_ body: Data) -> (status: Int, body: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let text = o["text"] as? String else {
            return json(400, ["error": "bad_body"])
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return json(422, ["error": "nothing_to_speak"]) }
        let clips = TryScript.turns.map { ($0.text, $0.audio) } + [TryScript.ambientHello]
        guard let clip = clips.first(where: { $0.0 == text })?.1, let packets = Self.packets(clip),
              let framed = try? VoiceNote(source: .phone, packets: packets).body() else {
            return json(503, ["error": "cerebellum_unavailable"])
        }
        return (200, framed)
    }

    /// `POST /api/messages`: typed JSON or a voice note (length-prefixed Opus packets), keyed by
    /// `Idempotency-Key`. 202 at once; the row, the cleaned text and the answer follow on `/live`.
    private func message(headers: [String: String], body: Data) -> (status: Int, body: Data) {
        let key = (headers["Idempotency-Key"] ?? "").lowercased()
        guard UUID(uuidString: key) != nil else { return json(400, ["error": "idempotency_key_required"]) }
        if let prev = receipts[key] { return (202, prev) }
        let at = now()
        switch headers["Content-Type"] {
        case "application/json":
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let text = o["text"] as? String ?? ""
            let atts = ((o["attachments"] as? [[String: Any]]) ?? []).map {
                ChannelAttachment(name: $0["name"] as? String ?? "", mime: $0["mime"] as? String ?? "",
                                  sha256: $0["sha256"] as? String)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !atts.isEmpty else {
                return json(400, ["error": "bad_body", "message_id": key])
            }
            let receipt = accept(key, at: at)
            // Delivered at once: the row, then the turn.
            append(ImlogEntry(at: at, kind: "typed", text: text, utt_id: key, attachments: atts.isEmpty ? nil : atts))
            answer(key)
            return receipt
        case PocketConstants.voiceContentType:
            var packets = 0, off = 0
            let bytes = [UInt8](body)
            while off + 2 <= bytes.count {
                off += 2 + (Int(bytes[off]) | Int(bytes[off + 1]) << 8)
                packets += 1
            }
            guard packets > 0, off == bytes.count, ["passport", "phone"].contains(headers["X-Voice-Source"] ?? "") else {
                return json(400, ["error": "bad_body", "message_id": key])
            }
            let receipt = accept(key, at: at)
            let text = TryScript.voiceText(seconds: Double(packets * PocketConstants.frameMs) / 1000)
            let source = headers["X-Voice-Source"]
            // Recognition takes a moment; the row carries the text the brain receives.
            queue.asyncAfter(deadline: .now() + Self.stepDelay) { [self] in
                append(ImlogEntry(at: now(), kind: "typed", text: text, utt_id: key, voice_source: source))
                frame(["type": "message", "id": key, "state": "cleaned", "text": text])
                answer(key)
            }
            return receipt
        default:
            return json(415, ["error": "unsupported_media_type", "message_id": key])
        }
    }

    private func accept(_ key: String, at: String) -> (status: Int, body: Data) {
        let res = (try? JSONSerialization.data(withJSONObject: ["message_id": key, "at": at])) ?? Data()
        receipts[key] = res
        return (202, res)
    }

    // MARK: the brain

    /// Plays the next scripted turn on `/live`: received, thinking, each tool call and result,
    /// the answer, any file, idle. Spoken when ambient mode holds the seat.
    private func answer(_ id: String) {
        let turns = TryScript.turns
        let turn = turns[next]
        next = next + 1 < turns.count ? next + 1 : min(1, turns.count - 1)
        var t: TimeInterval = 0
        func at(_ dt: TimeInterval, _ f: @escaping () -> Void) {
            t += dt
            queue.asyncAfter(deadline: .now() + t, execute: f)
        }
        let ids = [id]
        frame(["type": "turn", "message_ids": ids, "phase": "received"])
        at(Self.stepDelay) { self.frame(["type": "turn", "message_ids": ids, "phase": "thinking"]) }
        for tool in turn.tools {
            let input = String(decoding: (try? JSONSerialization.data(withJSONObject: tool.input)) ?? Data(), as: UTF8.self)
            at(Self.stepDelay) { self.frame(["type": "turn", "message_ids": ids, "phase": "tool", "label": tool.name, "input_summary": input]) }
            at(Self.stepDelay) { self.frame(["type": "turn", "message_ids": ids, "phase": "tool", "label": tool.name + ToolLine.resultSuffix]) }
        }
        let speech = "c-" + id
        at(Self.stepDelay) {
            self.frame(["type": "answer_final", "speech_id": speech, "message_ids": ids, "text": turn.text])
            let spoke = self.speak(id: speech, audio: turn.audio)
            self.append(ImlogEntry(at: self.now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: turn.text,
                                   unspoken: !spoke, message_ids: ids))
            if let f = turn.file, let url = Bundle.main.url(forResource: f.resource, withExtension: "md"),
               let data = try? Data(contentsOf: url) {
                let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                self.files[sha] = (data, f.mime)
                self.append(ImlogEntry(at: self.now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: "",
                                       attachments: [ChannelAttachment(name: f.name, mime: f.mime, sha256: sha)],
                                       unspoken: true, message_ids: ids))
            }
            self.frame(["type": "turn", "message_ids": ids, "phase": "idle"])
        }
    }

    /// Writes a row with the next cursor value (the channel's rule: never below the clock) and
    /// sends it.
    private func append(_ e: ImlogEntry) {
        var e = e
        lastSeq = max(lastSeq + 1, Int(Date().timeIntervalSince1970 * 1000))
        e.seq = lastSeq
        log.append(e)
        frame(["type": "row", "seq": lastSeq, "row": encode([e]).first ?? [:]])
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

    // MARK: the /live socket

    /// The app opened `/live` (`since` when it holds a cursor): `meta`, the rows after the
    /// cursor, then `ready`.
    func openLive(_ s: LiveSocket, path: String) {
        let items = URLComponents(string: path)?.queryItems ?? []
        let since = items.first { $0.name == "since" }?.value.flatMap(Int.init)
        let audioParam = items.first { $0.name == "audio" }?.value
        queue.async { [self] in
            live = s
            listening = false
            audio = audioParam == "1"
            frame(["type": "meta", "conn": "try-live"])
            if audio { frame(["type": "audio_params", "rate": AmbientEdge.rate]) }
            if let since {
                for e in log where (e.seq ?? 0) > since {
                    frame(["type": "row", "seq": e.seq ?? 0, "row": encode([e]).first ?? [:]])
                }
            }
            frame(["type": "ready", "seq": lastSeq, "turn": NSNull(), "messages": [[String: Any]](),
                   "api": PocketConstants.clientAPIMajor])
        }
    }

    func closeLive(_ s: LiveSocket) { queue.sync { if live === s { live = nil; listening = false; audio = false } } }
    func liveOpen(_ s: LiveSocket) -> Bool { queue.sync { live === s } }

    /// A text frame from the app.
    func liveReceived(_ f: [String: Any]) {
        queue.async { [self] in
            switch f["type"] as? String {
            case "hello":
                listening = true
                frame(["type": "meta", "role": AmbientEdge.Role.master.rawValue, "state": "listening"])
                if !greeted {
                    greeted = true
                    let hello = TryScript.ambientHello
                    let spoke = speak(id: "c-try-hello", audio: hello.audio)
                    append(ImlogEntry(at: now(), speaker: ImlogEntry.duoduoLabel, kind: "answer", text: hello.text,
                                      unspoken: !spoke))
                }
            case "hush":
                frame(["type": "stop_audio"])
            default:
                break
            }
        }
    }

    private func frame(_ f: [String: Any]) {
        guard let live, let d = try? JSONSerialization.data(withJSONObject: f) else { return }
        live.onText?(String(decoding: d, as: UTF8.self))
    }

    /// Declares the speech and sends the bundled clip as 20 ms Opus packets, as the channel does
    /// for TTS. Only to a mouth (`audio=1`), with ambient on or off. Returns whether it was spoken.
    @discardableResult
    private func speak(id: String, audio clip: String) -> Bool {
        guard audio, let live, let packets = Self.packets(clip) else { return false }
        frame(["type": "speech", "speech_id": id])
        for p in packets { live.onBinary?(p) }
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
