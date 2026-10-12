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

extension Tailnet {
    /// One streamed request (a read aloud). Blocks until the body ends, breaks or is cancelled;
    /// the 200 body goes to `request` as it arrives. Throws `TransportFailure` when no response
    /// arrived or the body broke.
    func stream(_ request: StreamRequest, method: String, path: String, headers: [String: String], body: Data,
                upTimeout: TimeInterval) throws -> (status: Int, body: Data) {
        if TryMode.active {
            let (status, data) = TryChannel.shared.request(method: method, path: path, headers: headers, body: body)
            guard status == 200 else { return (status, data) }
            request.onStreamData(data)
            return (status, Data())
        }
        try up(timeout: upTimeout)
        let hdr = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        // A request cancelled while tsnet came up is never sent.
        guard request.begin() else { throw TransportFailure.network("cancelled") }
        defer { request.end() }
        var err: NSError?
        let res = TsbridgeStream(request.id, method, path, hdr, body, request, &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
        guard let res else { throw TransportFailure.network("no response") }
        return (res.status, res.body ?? Data())
    }
}

/// The receiver of one streamed response body; `cancel()` ends the request, or keeps it from
/// being sent when it has not started.
final class StreamRequest: NSObject, TsbridgeStreamHandlerProtocol, @unchecked Sendable {
    private static let idLock = NSLock()
    private static var last: Int64 = 0

    let id: Int64
    private let onData: (StreamRequest, Data) -> Void
    private let lock = NSLock()
    private enum State { case idle, running, cancelled, done }
    private var state = State.idle

    /// `onData` gets each chunk with the request it belongs to.
    init(onData: @escaping (StreamRequest, Data) -> Void) {
        Self.idLock.lock()
        Self.last += 1
        id = Self.last
        Self.idLock.unlock()
        self.onData = onData
    }

    /// Marks the request as sent; false when it was cancelled first.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .idle else { return false }
        state = .running
        return true
    }

    func end() {
        lock.lock(); state = .done; lock.unlock()
    }

    func cancel() {
        lock.lock()
        let running = state == .running
        if state == .idle || running { state = .cancelled }
        lock.unlock()
        // Go is told only about a request it may hold; see `StreamCancel`.
        if running, !TryMode.active { TsbridgeStreamCancel(id) }
    }

    /// The bytes are Go heap memory, valid only during this call (see `LiveSocket.onLiveBinary`).
    func onStreamData(_ data: Data?) {
        guard let data else { return }
        onData(self, Data([UInt8](data)))
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

/// The room's one `/live` connection (design §7.1): conversation events always; with ambient
/// mode on, the app's `hello` takes the capture seat and Opus flows both ways. A connection cannot
/// un-hello, so leaving ambient mode closes it and opens a new one. Frames arrive on Go threads,
/// in order.
final class LiveSocket: NSObject, TsbridgeLiveHandlerProtocol, @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClosed: ((String) -> Void)?
    /// Writes go through their own queue: a write may block up to the bridge's write timeout on a
    /// dead path, and that must never stall capture or playback.
    private let sendQueue = DispatchQueue(label: "pocket.live.send", qos: .userInitiated)

    override init() {
        super.init()
        TsbridgeSetLiveHandler(self)
    }

    var isOpen: Bool { TryMode.active ? TryChannel.shared.liveOpen(self) : TsbridgeLiveIsOpen() }

    /// Dials `path` (`ChannelPaths.live`), replacing any held socket without a close report.
    func open(path: String, timeout: TimeInterval) throws {
        if TryMode.active { return TryChannel.shared.openLive(self, path: path) }
        try Tailnet.shared.up(timeout: timeout)
        var err: NSError?
        TsbridgeLiveOpen(path, Int64(timeout * 1000), &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
    }

    func ping(timeout: TimeInterval) -> Bool {
        if TryMode.active { return TryChannel.shared.liveOpen(self) }
        var err: NSError?
        TsbridgeLivePing(Int64(timeout * 1000), &err)
        return err == nil
    }

    /// Closes after the frames already queued have been written (each write is bounded). Not
    /// reported through `onClosed`.
    func close() {
        TryChannel.shared.closeLive(self)
        sendQueue.sync { TsbridgeLiveClose() }
    }

    func send(json: [String: Any]) {
        if TryMode.active { return TryChannel.shared.liveReceived(json) }
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        let s = String(decoding: d, as: UTF8.self)
        sendQueue.async { var e: NSError?; TsbridgeLiveSendText(s, &e) }
    }

    /// In try-it mode the microphone's packets go nowhere: nothing leaves the phone.
    func send(packet: Data) {
        if TryMode.active { return }
        sendQueue.async { var e: NSError?; TsbridgeLiveSendBinary(packet, &e) }
    }

    func onLiveText(_ text: String?) { if let text { onText?(text) } }
    /// gomobile passes callback `[]byte` arguments without a copy (`dataWithBytesNoCopy`, never
    /// freed): the bytes are Go heap memory, valid only during this call. Copy before the packet
    /// moves to another queue.
    func onLiveBinary(_ data: Data?) {
        guard let data else { return }
        onBinary?(Data([UInt8](data)))
    }
    func onLiveClosed(_ reason: String?) { onClosed?(reason ?? "") }
}
