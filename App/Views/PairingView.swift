// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import PocketCore
import SwiftUI

/// Redeems a pairing link: `POST /api/pair` to the link's host, without a token. The bridge is
/// pointed at that host only for this request and back at the stored connection when it fails.
@MainActor
final class PairingFlow: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String, linkSpent: Bool)
        case paired(roomTitle: String)
    }

    @Published var phase = Phase.idle

    func run(_ link: PairingLink, model: AppModel) {
        guard phase != .running else { return }
        if model.trying { model.stopTrying() }
        phase = .running
        Tailnet.shared.beginPairing(ChannelSettings(link: link))
        let tuning = PocketTuning.load()
        let client = ChannelClient(settings: ChannelSettings(link: link), tuning: tuning)
        Task {
            let up: Bool = await Task.detached { (try? Tailnet.shared.up(timeout: tuning.connectTimeout)) != nil }.value
            guard up else {
                return fail(String(localized: "Tailscale 没有连上。先登录 Tailscale，再重新配对。"), spent: false)
            }
            do {
                switch try await client.pair(link) {
                case .paired(let d):
                    model.paired(d, link: link)
                    phase = .paired(roomTitle: d.roomName)
                case .invalidCode:
                    fail(String(localized: "这个配对链接已失效（过期、已用过或不存在）。请让多多重新生成一个配对链接。"), spent: true)
                case .channelTooOld:
                    fail(String(localized: "家里的 ambient 需要升级后才能配对。") + String(localized: "按 ambient 部署文档 docs/deploy.md 的 Upgrading 一节升级"),
                         spent: false)
                case .failed(let why):
                    AppLog.shared.log("pair_error", ["err": why])
                    fail(String(localized: "配对失败：\(why)"), spent: false)
                }
            } catch {
                fail(String(localized: "连不上 \(link.host)：\(String(describing: error))"), spent: false)
            }
        }
    }

    private func fail(_ text: String, spent: Bool) {
        Tailnet.shared.endPairing(ChannelSettings.load(), token: DeviceCredentials.shared.token)
        phase = .failed(text, linkSpent: spent)
    }
}

/// Pairing (onboarding, Settings, and a tapped link): scan the QR code or paste the link the
/// channel's pairing command printed, confirm the host, pair.
struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var flow = PairingFlow()
    @State private var link: PairingLink?
    @State private var pasted = ""
    @State private var scanning = false
    @State private var parseError: String?
    var onboarding = false
    var onDone: () -> Void

    init(link: PairingLink? = nil, onboarding: Bool = false, onDone: @escaping () -> Void) {
        _link = State(initialValue: link)
        self.onboarding = onboarding
        self.onDone = onDone
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(String(localized: "配对这台手机")).font(.title2.weight(.bold))
                    Text(String(localized: "让多多生成一个配对链接，然后在这台手机上打开链接，或扫描它的二维码。"))
                        .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if onboarding, legacyInstall {
                Section {
                    Label(String(localized: "这一版需要先配对设备。让多多生成配对链接后，这台手机会回到原来的房间。"),
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
            if let link, !linkSpent {
                confirm(link)
            } else {
                source
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.grouped.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            QRScanSheet { text in
                scanning = false
                take(text)
            }
        }
    }

    /// Set up by an older version: a host and a room, no paired device.
    private var legacyInstall: Bool {
        let s = ChannelSettings.load()
        return !s.host.isEmpty && !s.room.isEmpty && s.deviceID.isEmpty
    }

    private var linkSpent: Bool {
        if case .failed(_, true) = flow.phase { true } else { false }
    }

    /// Where a link comes from: the camera or the pasteboard.
    @ViewBuilder private var source: some View {
        if case .failed(let text, true) = flow.phase {
            Section { Label(text, systemImage: "exclamationmark.circle").foregroundStyle(Palette.attention).font(.subheadline) }
        }
        Section {
            Button { scanning = true } label: { Label(String(localized: "扫描二维码"), systemImage: "qrcode.viewfinder") }
            Button {
                take(UIPasteboard.general.string ?? "")
            } label: { Label(String(localized: "粘贴配对链接"), systemImage: "doc.on.clipboard") }
            TextField(String(localized: "或在这里粘贴链接"), text: $pasted, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { take(pasted) }
                .onChange(of: pasted) { _, v in if PairingLink.parse(v) != nil { take(v) } }
            if let parseError { Text(parseError).font(.footnote).foregroundStyle(Palette.attention) }
        } footer: {
            Text(String(localized: "配对链接以 duoduopocket://pair 开头，只能用一次，过期后需要重新生成。"))
        }
        if onboarding {
            Section {
                Button(String(localized: "先体验")) { model.startTrying() }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder private func confirm(_ link: PairingLink) -> some View {
        Section {
            LabeledContent(String(localized: "主机"), value: link.host)
            if link.port != ChannelSettings.defaultPort || !link.tls {
                LabeledContent(String(localized: "端口 · HTTPS"),
                               value: "\(link.port) · \(link.tls ? String(localized: "开") : String(localized: "关"))")
            }
        } footer: {
            Text(String(localized: "只和你自己的多多配对。配对后这台手机只能进入多多为它绑定的房间。"))
        }
        Section {
            switch flow.phase {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(String(localized: "正在配对…")) }
            case .failed(let text, _):
                Label(text, systemImage: "xmark.circle.fill").foregroundStyle(Palette.attention).font(.subheadline)
            case .paired(let room):
                Label(String(localized: "已配对 · 房间「\(room)」"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ok)
            }
            if case .paired = flow.phase {
                Button(String(localized: "完成"), action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowBackground(Color.clear)
            } else {
                Button(String(localized: "配对")) { flow.run(link, model: model) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(flow.phase == .running)
                    .listRowBackground(Color.clear)
                Button(String(localized: "换一个链接")) {
                    self.link = nil
                    flow.phase = .idle
                }
                .frame(maxWidth: .infinity)
                .disabled(flow.phase == .running)
                .listRowBackground(Color.clear)
            }
        }
    }

    private func take(_ text: String) {
        guard let l = PairingLink.parse(text) else {
            parseError = String(localized: "没有找到配对链接")
            return
        }
        parseError = nil
        pasted = ""
        flow.phase = .idle
        link = l
    }
}

/// The pairing sheet opened by a tapped link or from Settings.
struct PairingSheet: View {
    let request: PairRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PairingView(link: request.link) { dismiss() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                }
        }
    }
}

// MARK: QR scanner

/// The camera, reading QR codes until one holds a pairing link.
struct QRScanSheet: View {
    var onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            Group {
                if denied {
                    ContentUnavailableView(String(localized: "不能使用相机"), systemImage: "camera.fill",
                                           description: Text(String(localized: "在系统设置里允许多多使用相机，或改用粘贴链接。")))
                } else {
                    QRScannerView(onFound: onFound, onUnavailable: { denied = true })
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .bottom) {
                            Text(String(localized: "对准配对二维码"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.5)))
                                .padding(.bottom, 40)
                        }
                }
            }
            .navigationTitle(String(localized: "扫描二维码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } } }
        }
    }
}

struct QRScannerView: UIViewRepresentable {
    var onFound: (String) -> Void
    var onUnavailable: () -> Void

    func makeCoordinator() -> Scanner { Scanner(onFound: onFound, onUnavailable: onUnavailable) }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = context.coordinator.session
        v.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Scanner) { coordinator.stop() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    /// Owns the capture session; it runs on its own queue (AVFoundation's start blocks).
    final class Scanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "pocket.qr")
        private let onFound: (String) -> Void
        private let onUnavailable: () -> Void
        private var found = false

        init(onFound: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onFound = onFound
            self.onUnavailable = onUnavailable
        }

        func start() {
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                guard granted else { return DispatchQueue.main.async { self.onUnavailable() } }
                queue.async { [self] in
                    guard let device = AVCaptureDevice.default(for: .video),
                          let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                        return DispatchQueue.main.async { self.onUnavailable() }
                    }
                    session.beginConfiguration()
                    session.addInput(input)
                    let output = AVCaptureMetadataOutput()
                    if session.canAddOutput(output) {
                        session.addOutput(output)
                        output.setMetadataObjectsDelegate(self, queue: .main)
                        output.metadataObjectTypes = [.qr]
                    }
                    session.commitConfiguration()
                    session.startRunning()
                }
            }
        }

        func stop() { queue.async { [session] in session.stopRunning() } }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !found else { return }
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                guard let s = code.stringValue, PairingLink.parse(s) != nil else { continue }
                found = true
                stop()
                onFound(s)
                return
            }
        }
    }
}
