// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import PocketCore
import Tsbridge

struct TailnetStatus: Decodable, Equatable {
    var backend_state: String
    var auth_url: String?
    var ips: [String]?
    var dns_name: String?
    var error: String?

    static let unknown = TailnetStatus(backend_state: "NotStarted")
}

/// The embedded tsnet node and native requests to the channel.
/// Every call into Go blocks, so callers stay off the main thread.
final class Tailnet: @unchecked Sendable {
    static let shared = Tailnet()
    /// Node name in the tailnet (visible in the admin console).
    static let hostname = "duoduo-pocket"

    private let queue = DispatchQueue(label: "pocket.tailnet")
    private var started = false

    let stateDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tsnet", isDirectory: true).path
    }()

    /// Starts tsnet once. Safe to call from any thread; returns immediately.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            let t0 = CPUClock.uptime()
            var err: NSError?
            TsbridgeStart(stateDir, Tailnet.hostname, &err)
            if let err {
                AppLog.shared.log("tsnet_start_error", ["err": err.localizedDescription])
                return
            }
            started = true
            AppLog.shared.log("tsnet_started", ["ms": Int((CPUClock.uptime() - t0) * 1000), "app": AppPhase.value])
        }
    }

    func apply(_ s: ChannelSettings) {
        TsbridgeSetTarget(s.host.trimmingCharacters(in: .whitespaces), s.port, s.tls)
    }

    func status() -> TailnetStatus {
        if TryMode.active { return TailnetStatus(backend_state: "Running") }
        return (try? JSONDecoder().decode(TailnetStatus.self, from: Data(TsbridgeStatus().utf8))) ?? .unknown
    }

    var tsnetLog: URL? {
        let p = TsbridgeTSLogPath()
        return p.isEmpty ? nil : URL(fileURLWithPath: p)
    }

    /// Waits for tsnet Running. Throws `TransportFailure.notConnected` with the backend state.
    func up(timeout: TimeInterval) throws {
        if TryMode.active { return }
        var err: NSError?
        TsbridgeUp(Int64(timeout * 1000), &err)
        if let err {
            let st = status()
            throw TransportFailure.notConnected("\(st.backend_state): \(err.localizedDescription)")
        }
    }

    func closeIdle() { TsbridgeCloseIdle() }

    /// Logs the node out (Settings › Tailscale › 退出登录).
    func logout() throws {
        var err: NSError?
        TsbridgeLogout(&err)
        if let err { throw err }
    }

    /// One blocking request over tsnet. Throws `TransportFailure` when no response arrived.
    func request(method: String, path: String, headers: [String: String] = [:], body: Data = Data(),
                 timeout: TimeInterval, upTimeout: TimeInterval) throws -> (status: Int, body: Data) {
        if TryMode.active { return TryChannel.shared.request(method: method, path: path, headers: headers, body: body) }
        try up(timeout: min(timeout, upTimeout))
        let hdr = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        var err: NSError?
        let res = TsbridgeDo(method, path, hdr, body, Int64(timeout * 1000), &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
        guard let res else { throw TransportFailure.network("no response") }
        return (res.status, res.body ?? Data())
    }
}

/// `ChannelTransport` over tsnet.
struct TsnetTransport: ChannelTransport {
    let tuning: PocketTuning

    func send(method: String, path: String, headers: [String: String], body: Data,
              timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result {
                    try Tailnet.shared.request(method: method, path: path, headers: headers, body: body,
                                               timeout: timeout, upTimeout: tuning.connectTimeout)
                })
            }
        }
    }
}

/// The channel's display socket: `/live?room=…` without `hello`, so it never takes the room's
/// capture seat. Frames arrive on Go threads and are handed to `onFrame`.
final class DisplaySocket: NSObject, TsbridgeFrameHandlerProtocol, @unchecked Sendable {
    var onFrame: (([String: Any]) -> Void)?
    var onClosed: ((String) -> Void)?

    override init() {
        super.init()
        TsbridgeSetHandler(self)
    }

    var isOpen: Bool { TryMode.active ? TryChannel.shared.displayOpen(self) : TsbridgeWSIsOpen() }

    func open(room: ChannelSettings, timeout: TimeInterval) throws {
        if TryMode.active { return TryChannel.shared.openDisplay(self) }
        try Tailnet.shared.up(timeout: timeout)
        var err: NSError?
        TsbridgeWSOpen("/live?room=\(room.roomQuery)", Int64(timeout * 1000), &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
    }

    func ping(timeout: TimeInterval) -> Bool {
        if TryMode.active { return TryChannel.shared.displayOpen(self) }
        var err: NSError?
        TsbridgeWSPing(Int64(timeout * 1000), &err)
        return err == nil
    }

    func close() {
        TryChannel.shared.closeDisplay(self)
        TsbridgeWSClose()
    }

    func onText(_ text: String?) {
        // Frames are per conversation event, never per audio packet (binary goes to the edge).
        guard let text,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        onFrame?(obj)
    }

    func onClosed(_ reason: String?) { onClosed?(reason ?? "") }
}

/// The ambient edge socket: a second `/live?room=…` that says `hello` and carries Opus both ways
/// (design §7.1). Frames arrive on Go threads in order.
final class EdgeSocket: NSObject, TsbridgeEdgeHandlerProtocol, @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    /// Writes go through their own queue: a write may block up to the bridge's write timeout on a
    /// dead path, and that must never stall capture or playback.
    private let sendQueue = DispatchQueue(label: "pocket.edge.send", qos: .userInitiated)

    override init() {
        super.init()
        TsbridgeSetEdgeHandler(self)
    }

    var isOpen: Bool { TryMode.active ? TryChannel.shared.edgeOpen(self) : TsbridgeEdgeIsOpen() }

    func open(room: ChannelSettings, timeout: TimeInterval) throws {
        if TryMode.active { return TryChannel.shared.openEdge(self) }
        try Tailnet.shared.up(timeout: timeout)
        var err: NSError?
        TsbridgeEdgeOpen("/live?room=\(room.roomQuery)", Int64(timeout * 1000), &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
    }

    /// Closes after the frames already queued have been written (each write is bounded).
    func close() {
        TryChannel.shared.closeEdge(self)
        sendQueue.sync { TsbridgeEdgeClose() }
    }

    func send(json: [String: Any]) {
        if TryMode.active { return TryChannel.shared.edgeReceived(json) }
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        let s = String(decoding: d, as: UTF8.self)
        sendQueue.async { var e: NSError?; TsbridgeEdgeSendText(s, &e) }
    }

    /// In try-it mode the microphone's packets go nowhere: nothing leaves the phone.
    func send(packet: Data) {
        if TryMode.active { return }
        sendQueue.async { var e: NSError?; TsbridgeEdgeSendBinary(packet, &e) }
    }

    func onEdgeText(_ text: String?) { if let text { onText?(text) } }
    /// gomobile passes callback `[]byte` arguments without a copy (`dataWithBytesNoCopy`, never
    /// freed): the bytes are Go heap memory, valid only during this call. Copy before the packet
    /// moves to another queue.
    func onEdgeBinary(_ data: Data?) {
        guard let data else { return }
        onBinary?(Data([UInt8](data)))
    }
    func onEdgeClosed(_ reason: String?) { onClosed?(reason ?? "") }
}
