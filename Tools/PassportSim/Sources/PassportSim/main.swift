// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// PassportSim: development tool that plays the Passport's side of the BLE link
// (docs/ble-protocol.md §4-§7) on a Mac. Not part of the app.
//
// Run: Tools/PassportSim/run.sh [options]   (builds, wraps in a .app for the Bluetooth
// permission, launches; drive it through logs/control). `swift run PassportSim` also works
// when the terminal already has Bluetooth permission.
//
// Advertises the primary service with TX (notify) and RX (write without response). On
// subscribe it sends INFO. A press streams real Opus packets (speech synthesized with `say`, or
// a WAV file) in real time: PRESS_START, AUDIO per 20 ms, PRESS_END. After a press it sends
// KEEPALIVE until REPLY_DONE, like the device. Every phone message is decoded and logged.
//
// Commands (stdin, or lines written to the --control FIFO):
//   press <text>          speak <text> with the zh_CN voice, as one press
//   pressfile <wav>       one press from a 16 kHz mono 16-bit WAV
//   hold <seconds>        a press of silence (link and assembly only)
//   status <pct> <0|1|255> send STATUS (255 = charging unknown)
//   info                  resend INFO
//   drop <n>              drop the next n AUDIO packets (tests gap counting)
//   quit

import CoreBluetooth
import Foundation
import PocketCore
import PocketOpus

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: options

struct Options {
    var secure = true
    var protoMajor = PocketConstants.protoMajor
    var protoMinor = PocketConstants.protoMinor
    var firmware = "passport-sim-0.1"
    var battery: UInt8 = 80
    var preroll = false
    /// Device-side keepalive period. Basis: a BLE notification gives the app about 10 s of
    /// background time, so a period below that keeps it awake while a reply is pending.
    var keepaliveSeconds = 5.0
    var voice = "Tingting"
    var log = "logs/passport-sim-\(Int(Date().timeIntervalSince1970)).jsonl"
    var control: String?
}

var opt = Options()
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--insecure": opt.secure = false
    case "--proto-major": opt.protoMajor = UInt8(argv.next()!)!
    case "--proto-minor": opt.protoMinor = UInt8(argv.next()!)!
    case "--firmware": opt.firmware = argv.next()!
    case "--preroll": opt.preroll = true
    case "--keepalive-s": opt.keepaliveSeconds = Double(argv.next()!)!
    case "--voice": opt.voice = argv.next()!
    case "--log": opt.log = argv.next()!
    case "--control": opt.control = argv.next()!
    default:
        FileHandle.standardError.write("""
        usage: PassportSim [--insecure] [--proto-major N] [--proto-minor N] [--firmware S] [--preroll]
                           [--keepalive-s S] [--voice NAME] [--log PATH] [--control FIFO]\n
        """.data(using: .utf8)!)
        exit(2)
    }
}

// MARK: log

try? FileManager.default.createDirectory(at: URL(fileURLWithPath: opt.log).deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
FileManager.default.createFile(atPath: opt.log, contents: nil)
let logHandle = FileHandle(forWritingAtPath: opt.log)!

func log(_ ev: String, _ fields: [String: Any] = [:]) {
    var obj = fields
    obj["ev"] = ev
    obj["t"] = Date().timeIntervalSince1970
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    logHandle.write(data + Data([0x0a]))
    print("[\(ev)] " + String(decoding: data, as: UTF8.self))
}

// MARK: audio

/// 16-bit mono samples from a WAV file (any chunk layout; must already be 16 kHz mono PCM16).
func readWAV(_ path: String) throws -> [Int16] {
    let d = try Data(contentsOf: URL(fileURLWithPath: path))
    var i = 12
    var fmtOK = false
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i + 4], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        let body = d[(i + 8)..<min(i + 8 + size, d.count)]
        if id == "fmt " {
            let b = Array(body)
            let channels = Int(b[2]) | Int(b[3]) << 8
            let rate = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
            let bits = Int(b[14]) | Int(b[15]) << 8
            guard channels == 1, rate == PocketConstants.sampleRate, bits == 16 else {
                throw NSError(domain: "wav", code: 1, userInfo: [NSLocalizedDescriptionKey: "need 16 kHz mono 16-bit, got \(rate) Hz \(channels) ch \(bits) bit"])
            }
            fmtOK = true
        } else if id == "data", fmtOK {
            return body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        i += 8 + size + (size & 1)
    }
    throw NSError(domain: "wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "no data chunk"])
}

func synthesize(_ text: String) throws -> [Int16] {
    let out = NSTemporaryDirectory() + "passport-sim-\(UUID().uuidString).wav"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", opt.voice, "-o", out, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: out) }
    return try readWAV(out)
}

// MARK: peripheral

final class Sim: NSObject, CBPeripheralManagerDelegate {
    let queue = DispatchQueue(label: "passport-sim")
    var pm: CBPeripheralManager!
    let service = CBUUID(string: PocketConstants.serviceUUID)
    let tx: CBMutableCharacteristic
    let rx: CBMutableCharacteristic
    var central: CBCentral?
    var outbox: [Data] = []
    var decoder = PhoneLinkDecoder()

    var pressID: UInt16 = 0
    var pressing = false
    var dropNext = 0
    var waitingReply = false
    var keepaliveTimer: DispatchSourceTimer?
    var lastReply: [UInt32: String] = [:]

    override init() {
        // TX/RX need an encrypted link (§4, §5); the first subscribe triggers pairing.
        tx = CBMutableCharacteristic(type: CBUUID(string: PocketConstants.txCharacteristicUUID),
                                     properties: opt.secure ? [.notifyEncryptionRequired] : [.notify],
                                     value: nil, permissions: opt.secure ? [.readEncryptionRequired] : [.readable])
        rx = CBMutableCharacteristic(type: CBUUID(string: PocketConstants.rxCharacteristicUUID),
                                     properties: [.writeWithoutResponse, .write], value: nil,
                                     permissions: opt.secure ? [.writeEncryptionRequired] : [.writeable])
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: queue)
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        log("state", ["state": p.state.rawValue, "auth": CBManager.authorization.rawValue])
        guard p.state == .poweredOn else { return }
        let svc = CBMutableService(type: service, primary: true)
        svc.characteristics = [tx, rx]
        p.removeAllServices()
        p.add(svc)
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        if let error { return log("add_service_error", ["err": "\(error)"]) }
        p.startAdvertising([CBAdvertisementDataLocalNameKey: "Passport-Sim",
                            CBAdvertisementDataServiceUUIDsKey: [service]])
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        log("advertising", ["ok": error == nil, "secure": opt.secure])
    }

    func peripheralManager(_ p: CBPeripheralManager, central c: CBCentral, didSubscribeTo ch: CBCharacteristic) {
        central = c
        log("subscribe", ["central": c.identifier.uuidString, "max_update_len": c.maximumUpdateValueLength])
        sendInfo()
    }

    func peripheralManager(_ p: CBPeripheralManager, central c: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        log("unsubscribe", ["central": c.identifier.uuidString])
        central = nil
        decoder.reset()
        outbox.removeAll()
        stopKeepalive()
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard let v = r.value else { continue }
            do {
                if let m = try decoder.push(v) { received(m) }
            } catch {
                log("rx_error", ["err": "\(error)", "len": v.count])
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func received(_ m: PhoneMessage) {
        switch m {
        case .result(let id, let code, let text):
            log("RESULT", ["press": id, "code": code.rawValue, "name": "\(code)", "text": text])
        case .reply(let id, let final, let text):
            lastReply[id] = text
            log("REPLY", ["reply_id": id, "final": final, "len": text.count, "text": text])
        case .replyDone(let id):
            log("REPLY_DONE", ["reply_id": id, "had_text": lastReply[id] != nil])
            stopKeepalive()
        case .appState(let s, let language):
            log("APP_STATE", ["state": s.rawValue, "name": "\(s)", "language": language.map { "\($0)" } ?? "unchanged"])
        case .work(let phase, let label):
            // §9: the device shows the phase while it waits; the wait itself ends only on
            // REPLY_DONE, so keepalives continue through WORK 0.
            log("WORK", ["phase": phase.rawValue, "name": "\(phase)", "label": label, "waiting": waitingReply])
        }
    }

    // MARK: sending

    func send(_ m: DeviceMessage) {
        guard let c = central else { return }
        do {
            outbox += try m.fragments(attPayload: c.maximumUpdateValueLength)
        } catch {
            log("tx_error", ["err": "\(error)"])
        }
        flush()
    }

    func flush() {
        while let head = outbox.first {
            guard pm.updateValue(head, for: tx, onSubscribedCentrals: nil) else { return }
            outbox.removeFirst()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) { flush() }

    func sendInfo() {
        send(.info(DeviceInfo(protoMajor: opt.protoMajor, protoMinor: opt.protoMinor, firmware: opt.firmware,
                              battery: opt.battery, charging: .unknown, preroll: opt.preroll)))
        log("INFO", ["proto": "\(opt.protoMajor).\(opt.protoMinor)", "fw": opt.firmware])
    }

    // MARK: press

    func press(samples: [Int16], label: String) {
        queue.async { [self] in
            guard central != nil else { return log("press_refused", ["why": "phone not connected"]) }
            guard !pressing else { return log("press_refused", ["why": "already pressing"]) }
            let packets: [Data]
            do {
                let enc = try OpusVoiceEncoder()
                packets = try enc.push(samples)
            } catch {
                return log("encode_error", ["err": "\(error)"])
            }
            stopKeepalive()
            pressing = true
            pressID &+= 1
            let id = pressID
            send(.pressStart(pressID: id))
            log("PRESS_START", ["press": id, "label": label, "packets": packets.count,
                                "audio_ms": packets.count * PocketConstants.frameMs])
            var seq: UInt16 = 0
            var sent: UInt16 = 0
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(PocketConstants.frameMs), leeway: .nanoseconds(0))
            timer.setEventHandler { [self] in
                if Int(seq) >= packets.count {
                    timer.cancel()
                    send(.pressEnd(pressID: id, packetCount: seq))
                    log("PRESS_END", ["press": id, "count": seq, "sent": sent])
                    pressing = false
                    startKeepalive(id)
                    return
                }
                if dropNext > 0 {
                    dropNext -= 1
                } else {
                    send(.audio(pressID: id, seq: seq, packet: packets[Int(seq)]))
                    sent += 1
                }
                seq += 1
            }
            timer.resume()
        }
    }

    func startKeepalive(_ id: UInt16) {
        waitingReply = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + opt.keepaliveSeconds, repeating: opt.keepaliveSeconds)
        t.setEventHandler { [self] in
            send(.keepalive(pressID: id))
            log("KEEPALIVE", ["press": id])
        }
        t.resume()
        keepaliveTimer = t
    }

    func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        waitingReply = false
    }
}

// MARK: commands

let sim = Sim()
log("start", ["pid": Int(getpid()), "secure": opt.secure, "log": opt.log])

func run(_ line: String) {
    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
    guard let cmd = parts.first else { return }
    let arg = parts.count > 1 ? parts[1] : ""
    switch cmd {
    case "press":
        do { sim.press(samples: try synthesize(arg.isEmpty ? "你好多多" : arg), label: arg) } catch { log("say_error", ["err": "\(error)"]) }
    case "pressfile":
        do { sim.press(samples: try readWAV(arg), label: arg) } catch { log("wav_error", ["err": "\(error)"]) }
    case "hold":
        let s = Double(arg) ?? 1
        sim.press(samples: [Int16](repeating: 0, count: Int(s * Double(PocketConstants.sampleRate))), label: "silence \(s)s")
    case "status":
        let f = arg.split(separator: " ")
        let b = UInt8(f.first ?? "50") ?? 50
        let c: Charging = f.count > 1 ? Charging(wire: UInt8(f[1]) ?? 0xFF) : .unknown
        sim.queue.async { sim.send(.status(battery: b, charging: c)) }
        log("STATUS", ["battery": b, "charging": c.rawValue])
    case "info": sim.queue.async { sim.sendInfo() }
    case "drop": sim.queue.async { sim.dropNext = Int(arg) ?? 1 }
    case "quit": log("quit"); exit(0)
    default: print("commands: press <text> | pressfile <wav> | hold <s> | status <pct> <0|1> | info | drop <n> | quit")
    }
}

DispatchQueue.global().async {
    while let line = readLine() { run(line) }
}

if let fifo = opt.control {
    unlink(fifo)
    mkfifo(fifo, 0o600)
    DispatchQueue.global().async {
        while true {
            guard let f = fopen(fifo, "r") else { sleep(1); continue }
            var buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, Int32(buf.count), f) != nil {
                run(String(cString: buf).trimmingCharacters(in: .newlines))
            }
            fclose(f)
        }
    }
}

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { log("quit", ["signal": "TERM"]); exit(0) }
term.resume()

dispatchMain()
