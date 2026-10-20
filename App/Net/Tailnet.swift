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

    private let targetLock = NSLock()
    /// Counts target changes; the current one, and whether it carries the device token.
    private var targetGeneration = 0
    private var targetHasToken = false
    /// A pairing holds the target: other callers' `apply` (settings, foreground) waits for it,
    /// so the pair request cannot be sent to the stored host.
    private var pairing = false

    /// Points the bridge at `s` with the device token for it. The bridge sends the token only to
    /// the target it was set with. Ignored while a pairing holds the target; `endPairing` sets
    /// the one that follows it.
    func apply(_ s: ChannelSettings, token: String? = DeviceCredentials.shared.token) {
        targetLock.lock(); defer { targetLock.unlock() }
        guard !pairing else { return }
        setTarget(s, token: token)
    }

    /// Points the bridge at a pairing link's host, without a token, until `endPairing`.
    func beginPairing(_ s: ChannelSettings) {
        targetLock.lock(); defer { targetLock.unlock() }
        pairing = true
        setTarget(s, token: nil)
    }

    /// Ends the pairing with the target that follows it: the paired host and its new token, or
    /// the stored connection after a failure.
    func endPairing(_ s: ChannelSettings, token: String?) {
        targetLock.lock(); defer { targetLock.unlock() }
        pairing = false
        setTarget(s, token: token)
    }

    /// Caller holds `targetLock`.
    private func setTarget(_ s: ChannelSettings, token: String?) {
        targetGeneration += 1
        targetHasToken = !(token ?? "").isEmpty
        TsbridgeSetTarget(s.host.trimmingCharacters(in: .whitespaces), s.port, s.tls, token ?? "")
    }

    /// Requests that need the token are not sent without one: an unpaired app (or one whose
    /// target is held by a pairing) reaches only `/healthz` and `/api/pair`.
    func checkPaired(_ path: String) throws {
        guard !TryMode.active, DeviceAuth.needsToken(path: path), !targetSnapshot().hasToken else { return }
        throw TransportFailure.notConnected("not paired")
    }

    /// The target a request is about to use.
    func targetSnapshot() -> (generation: Int, hasToken: Bool) {
        targetLock.lock(); defer { targetLock.unlock() }
        return (targetGeneration, targetHasToken)
    }

    /// The channel rejected the token sent under `target`. Only a rejection of the stored token,
    /// on the target still set, counts: a request without a token (pairing, a target being
    /// replaced) says nothing about it.
    func rejected(under target: (generation: Int, hasToken: Bool), _ source: String) {
        guard target.hasToken, targetSnapshot().generation == target.generation else { return }
        DeviceCredentials.shared.reportUnauthorized(source)
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
        try checkPaired(path)
        try up(timeout: min(timeout, upTimeout))
        let hdr = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        let target = targetSnapshot()
        var err: NSError?
        let res = TsbridgeDo(method, path, hdr, body, Int64(timeout * 1000), &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
        guard let res else { throw TransportFailure.network("no response") }
        let data = res.body ?? Data()
        // A 401 `unauthorized`: the token is gone, and every caller stops until the user pairs.
        if DeviceAuth.isUnauthorized(status: res.status, body: data) { rejected(under: target, "http") }
        return (res.status, data)
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
        try checkPaired(path)
        try up(timeout: upTimeout)
        let hdr = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        let target = targetSnapshot()
        // A request cancelled while tsnet came up is never sent.
        guard request.begin() else { throw TransportFailure.network("cancelled") }
        defer { request.end() }
        var err: NSError?
        let res = TsbridgeStream(request.id, method, path, hdr, body, request, &err)
        if let err { throw TransportFailure.network(err.localizedDescription) }
        guard let res else { throw TransportFailure.network("no response") }
        let data = res.body ?? Data()
        if DeviceAuth.isUnauthorized(status: res.status, body: data) { rejected(under: target, "http") }
        return (res.status, data)
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

    /// Dials `path` (`ChannelPaths.live`) with extra upgrade `headers`, replacing any held socket
    /// without a close report.
    func open(path: String, headers: [String: String] = [:], timeout: TimeInterval) throws {
        if TryMode.active { return TryChannel.shared.openLive(self, path: path) }
        try Tailnet.shared.checkPaired(path)
        try Tailnet.shared.up(timeout: timeout)
        let target = Tailnet.shared.targetSnapshot()
        let hdr = headers.isEmpty ? "" : String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        var err: NSError?
        // The bridge adds the target's device token to the upgrade request.
        TsbridgeLiveOpen(path, hdr, Int64(timeout * 1000), &err)
        if let err {
            if DeviceAuth.isUnauthorizedOpenError(err.localizedDescription) {
                Tailnet.shared.rejected(under: target, "live_open")
            }
            throw TransportFailure.network(err.localizedDescription)
        }
        liveTarget.withLock { $0 = target }
    }

    /// The target the held socket was opened under.
    private let liveTarget = Locked<(generation: Int, hasToken: Bool)>((0, false))

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
    func onLiveClosed(_ reason: String?) {
        let r = reason ?? ""
        // Reported before the close, so the redial it triggers already sees the rejection.
        if DeviceAuth.isUnauthorizedClose(r) { Tailnet.shared.rejected(under: liveTarget.withLock { $0 }, "live_close") }
        onClosed?(r)
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ f: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return f(&value)
    }
}
