// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import CryptoKit
@testable import PocketCore
import XCTest

/// The shared camera framing vectors (`Fixtures/camera-v1.json`, a copy of the ambient protocol
/// package's `test-vectors/camera-v1.json` at ambient a93017d; the test pins its sha256, so a
/// copy that drifted from that file fails here): this app encodes the edge link, so
/// every valid edge case that is not decode-only is encoded and compared. The header and the
/// payload must match byte for byte; config blocks are JSON objects compared by value, since key
/// order and spacing are free. The control cases an edge receives (`camera`, `meta`) are read as
/// the app reads them; `camera_declined` is the edge's own frame and is not read here.
final class CameraVectorTests: XCTestCase {
    private func all() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/camera-v1.json")
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sha, "197a87cd4a0c397b46993b374e56b049cfacde0c87ac1c1cd4685a3f72f3a13e")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    /// The valid edge cases an encoder reproduces.
    private func cases() throws -> [[String: Any]] {
        try all().filter { $0["link"] as? String == "edge" && $0["expect"] != nil && $0["decode_only"] as? Bool != true }
    }

    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    /// A block's JSON object and the offset after it.
    private func block(_ d: Data, _ o: Int) throws -> ([String: Any], Int) {
        let n = Int(d[o]) | Int(d[o + 1]) << 8
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: d[(o + 2)..<(o + 2 + n)]) as? [String: Any])
        return (obj, o + 2 + n)
    }

    func testEdgeAudioFrames() throws {
        var checked = 0
        for c in try cases() {
            let e = try XCTUnwrap(c["expect"] as? [String: Any])
            guard e["kind"] as? String == "audio" else { continue }
            let opus = hex(try XCTUnwrap(e["opus"] as? String))
            let block = Data([UInt8(opus.count >> 8), UInt8(opus.count & 0xff)]) + opus
            let framed = try XCTUnwrap(MediaFraming.audio(lengthPrefixed: block))
            XCTAssertEqual(framed.dropFirst(2), hex(try XCTUnwrap(c["hex"] as? String))[...], "\(c["name"] ?? "")")
            checked += 1
        }
        // Every case of the pinned file is read: a filter that skips one fails the count.
        XCTAssertEqual(checked, 1)
    }

    func testEdgeVideoFrames() throws {
        var checked = 0
        for c in try cases() {
            let name = c["name"] as? String ?? ""
            let e = try XCTUnwrap(c["expect"] as? [String: Any])
            guard e["kind"] as? String == "video" else { continue }
            let config = e["config"] as? [String: Any]
            // This app always names the camera; an absent `view` is a receiver's case.
            if let config, config["view"] == nil { continue }
            let key = try XCTUnwrap(e["key"] as? Bool)
            let seq = try XCTUnwrap((e["seq"] as? NSNumber)?.uint32Value)
            let at = try XCTUnwrap((e["at"] as? NSNumber)?.int64Value)
            let payload = hex(try XCTUnwrap(e["payload"] as? String))
            let rateObj = e["rate"] as? [String: Any]
            let told = SightRate(fps: 25, bitrate: 1_200_000)
            let rate = rateObj.map { SightRate(fps: $0["fps"] as! Int, bitrate: $0["bitrate"] as! Int) } ?? told
            // A delta carries a rate config only when the rate differs from the one already told.
            var u = SightUplink(seq: seq, declared: rateObj == nil ? told : nil)
            let view = (config?["view"] as? String).flatMap(SightView.init) ?? .facing
            let f = try XCTUnwrap(u.video(key: key, at: Int(at), payload: payload,
                                          width: config?["width"] as? Int ?? 0, height: config?["height"] as? Int ?? 0,
                                          view: view, rate: rate, maxFrameBytes: 1 << 20), name)
            let want = hex(try XCTUnwrap(c["hex"] as? String))
            XCTAssertEqual(f.prefix(14), want.prefix(14), "\(name): kind, flags, seq, at")
            var o = 14, w = 14
            if let config {
                let (mine, next) = try block(f, o)
                let (theirs, wnext) = try block(want, w)
                XCTAssertEqual(NSDictionary(dictionary: mine), NSDictionary(dictionary: config), name)
                XCTAssertEqual(NSDictionary(dictionary: theirs), NSDictionary(dictionary: config), name)
                o = next; w = wnext
            }
            if let rateObj {
                let (mine, next) = try block(f, o)
                let (_, wnext) = try block(want, w)
                XCTAssertEqual(NSDictionary(dictionary: mine), NSDictionary(dictionary: rateObj), name)
                o = next; w = wnext
            }
            XCTAssertEqual(f[o...], want[w...], "\(name): payload")
            checked += 1
        }
        XCTAssertEqual(checked, 20)
    }

    func testCameraControlFrames() throws {
        var checked = 0
        for c in try all() where c["link"] as? String == "control" {
            let name = c["name"] as? String ?? ""
            let f = try XCTUnwrap(c["frame"] as? [String: Any])
            let e = try XCTUnwrap(c["expect"] as? [String: Any])
            let outcome = try XCTUnwrap(e["outcome"] as? String)
            switch f["type"] as? String {
            case "camera":
                var edge = AmbientEdge(room: "r")
                edge.framed = true
                let got: String
                switch edge.frame(f).first {
                case .camera(let ask, _, let reason)?:
                    got = ask != nil ? "start" : "stop"
                    if ask == nil { XCTAssertEqual(reason, e["reason"] as? String, name) }
                default: got = "invalid"
                }
                XCTAssertEqual(got, outcome, name)
            case "meta":
                let offered = c["offered"] as? Int
                switch LiveMedia.answer(f[LiveMedia.param], offered: offered) {
                case .framed(let v):
                    XCTAssertEqual("framed", outcome, name)
                    XCTAssertEqual(v, e["version"] as? Int, name)
                case .unframed: XCTAssertEqual("unframed", outcome, name)
                case .invalid: XCTAssertEqual("invalid", outcome, name)
                }
            default: continue
            }
            checked += 1
        }
        XCTAssertEqual(checked, 39)
    }
}
