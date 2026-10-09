// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AuthenticationServices
import PocketCore
import SwiftUI

/// Settings (design §4.9).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ui.haptics") private var haptics = true
    @AppStorage(AmbientPolicy.backgroundKey) private var keepListening = true
    @AppStorage(AudioPreferences.headsetMicKey) private var headsetMic = false

    var body: some View {
        NavigationStack {
            List {
                if model.trying {
                    Section {
                        Button(String(localized: "退出体验")) {
                            dismiss()
                            model.stopTrying()
                        }
                    } footer: {
                        Text(String(localized: "体验模式里的消息、录音和文件只留在这台手机上，退出后全部清除。"))
                    }
                }
                Section {
                    NavigationLink { ConnectionEditor(mode: .settings) } label: {
                        row("link", Palette.brand, String(localized: "频道主机"), model.settings.host.isEmpty ? String(localized: "未设置") : model.settings.host)
                    }
                    NavigationLink { ConnectionEditor(mode: .settings) } label: {
                        row("number", Palette.brand, String(localized: "房间"), model.settings.room, caption: roomCaption)
                    }
                    NavigationLink { TailscaleDetail() } label: {
                        row("shield.lefthalf.filled", Palette.ok, "Tailscale", tailnetText, stacked: true)
                    }
                } header: { Text(String(localized: "连接")) } footer: {
                    Text(String(localized: "端口和 HTTPS 在「频道主机」里。多多随身只走你的 Tailscale 网络。"))
                }
                Section {
                    row("speaker.wave.2", Palette.attention, String(localized: "环境模式的声音"), model.ambient.isOn ? model.ambient.route : String(localized: "扬声器"))
                    Toggle(isOn: $keepListening) { label("lock.iphone", Palette.secondary, String(localized: "离开 App 后继续听")) }
                    Toggle(isOn: $haptics) { label("hand.tap", Palette.secondary, String(localized: "按住说话的触感反馈")) }
                    Picker(selection: $headsetMic) {
                        Text(String(localized: "手机麦克风")).tag(false)
                        Text(String(localized: "AirPods 麦克风")).tag(true)
                    } label: {
                        label("airpodspro", Palette.secondary, String(localized: "连着 AirPods 时用"))
                    }
                } header: { Text(String(localized: "声音")) } footer: {
                    Text(headsetMic
                         ? String(localized: "按住说话时 AirPods 切到通话模式，正在放的音乐音质会变差，松手后恢复。")
                         : String(localized: "按住说话用手机麦克风，AirPods 继续放声音，音质不变。"))
                }
                Section(String(localized: "配件")) {
                    NavigationLink { PassportSheet(pushed: true) } label: {
                        row("candybarphone", Palette.tertiary, "Passport", passportText, stacked: true)
                    }
                }
                Section(String(localized: "外观")) {
                    HStack {
                        label("circle.lefthalf.filled", Palette.secondary, String(localized: "主题"))
                        Spacer()
                        Picker(String(localized: "主题"), selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                            Text(String(localized: "跟随系统")).tag("system")
                            Text(String(localized: "浅色")).tag("light")
                            Text(String(localized: "深色")).tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }
                Section(String(localized: "诊断")) {
                    ShareLink(items: AppLog.shared.exportFiles(extra: [Tailnet.shared.tsnetLog].compactMap { $0 })) {
                        row("tray.and.arrow.up", Palette.secondary, String(localized: "导出日志"), "")
                    }
                    NavigationLink { AboutView(version: version) } label: {
                        row("info.circle", Palette.secondary, String(localized: "关于多多随身"), version)
                    }
                    if let issues = model.chat.room?.configIssues, !issues.isEmpty {
                        DisclosureGroup(String(localized: "频道配置提示（\(issues.count)）")) {
                            ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.secondary) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.grouped.ignoresSafeArea())
            .navigationTitle(String(localized: "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
        }
    }

    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "") (\(i?["CFBundleVersion"] as? String ?? ""))"
    }

    private var tailnetText: String {
        let t = model.tailnet
        switch t.backend_state {
        case "Running": return String(localized: "已登录 · 节点 \(Tailnet.hostname)")
        case "NeedsLogin", "NeedsMachineAuth": return String(localized: "需要登录")
        case "Starting": return String(localized: "正在连接")
        default: return t.backend_state
        }
    }

    private var passportText: String {
        let d = model.device
        guard d.link == .ready else { return d.deviceName == nil ? String(localized: "未配对") : String(localized: "未连接") }
        var parts = [String(localized: "已连接")]
        if let b = d.battery { parts.append("\(b)%") }
        if let f = d.info?.firmware { parts.append(String(localized: "固件 \(f)")) }
        return parts.joined(separator: " · ")
    }

    private func label(_ icon: String, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
            Text(title)
        }
    }

    /// The channel's display name for the room, when it differs from the ID. It is user data and
    /// is shown as entered, in any UI language.
    private var roomCaption: String? {
        guard let name = model.chat.room?.roomName, !name.isEmpty, name != model.settings.room else { return nil }
        return name
    }

    private func row(_ icon: String, _ color: Color, _ title: String, _ value: String, stacked: Bool = false,
                     caption: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(value).font(.caption).foregroundStyle(Palette.tertiary)
                }
                Spacer()
            } else {
                if let caption {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(caption).font(.caption).foregroundStyle(Palette.tertiary)
                    }
                } else {
                    Text(title)
                }
                Spacer()
                Text(value).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .foregroundStyle(Palette.text)
    }
}

/// Whether ambient continues after the app leaves the foreground (decision Q3: yes by default,
/// through the `audio` background mode; the user can choose otherwise).
enum AmbientPolicy {
    static let backgroundKey = "ambient.background"
    static var continuesInBackground: Bool { UserDefaults.standard.object(forKey: backgroundKey) as? Bool ?? true }
}

struct TailscaleDetail: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "状态"), value: model.tailnet.backend_state)
                LabeledContent(String(localized: "节点"), value: Tailnet.hostname)
                if let ip = model.tailnet.ips?.first { LabeledContent(String(localized: "地址"), value: ip) }
                if let e = model.tailnet.error { Text(e).font(.footnote).foregroundStyle(Palette.attention) }
            }
            Section {
                if model.tailnet.backend_state.hasPrefix("Needs") {
                    Button(String(localized: "登录 Tailscale")) { TailnetLogin.shared.start(model.tailnet) }
                } else {
                    Button(String(localized: "退出登录"), role: .destructive) { confirm = true }
                }
            } footer: {
                Text(String(localized: "多多随身作为节点 \(Tailnet.hostname) 出现在你的 tailnet 里。退出后需要重新登录才能连上多多。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.grouped.ignoresSafeArea())
        .navigationTitle("Tailscale")
        .confirmationDialog(String(localized: "退出 Tailscale 登录？"), isPresented: $confirm, titleVisibility: .visible) {
            Button(String(localized: "退出登录"), role: .destructive) {
                Task.detached { try? Tailnet.shared.logout() }
            }
        }
    }
}

/// Host, room, port and HTTPS with the live check (onboarding step 2 and Settings).
struct ConnectionEditor: View {
    enum Mode { case settings, onboarding }
    let mode: Mode
    var onDone: (() -> Void)?
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ChannelSettings.load()
    @StateObject private var check = ConnectionCheck()
    @State private var advanced = false

    var body: some View {
        List {
            if mode == .onboarding {
                Section {
                    VStack(spacing: 6) {
                        Text(String(localized: "找到多多")).font(.title.weight(.bold))
                        Text(String(localized: "填写频道所在的主机和这台手机专用的房间。"))
                            .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                LabeledContent(String(localized: "主机")) {
                    TextField("your-host.tailnet.ts.net", text: $draft.host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                LabeledContent(String(localized: "房间")) {
                    TextField(String(localized: "房间名"), text: $draft.room)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                DisclosureGroup(isExpanded: $advanced) {
                    Toggle("HTTPS", isOn: $draft.tls)
                    LabeledContent(String(localized: "端口")) {
                        TextField("443", value: $draft.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                } label: {
                    Text(String(localized: "端口 · HTTPS")).foregroundStyle(Palette.secondary)
                        .badge(Text("\(draft.port) · \(draft.tls ? String(localized: "开") : String(localized: "关"))"))
                }
            } footer: {
                Text(String(localized: "频道通过 tailnet 访问，例如用 tailscale serve 发布的主机名，默认 HTTPS 443。"))
            }
            Section {
                ForEach(check.items) { item in
                    HStack(spacing: 8) {
                        switch item.state {
                        case .pending: Image(systemName: "circle.dotted").foregroundStyle(Palette.placeholder)
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.attention)
                        }
                        Text(item.text).font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !check.rooms.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "这个频道有这些房间：")).font(.caption).foregroundStyle(Palette.secondary)
                        HStack {
                            ForEach(check.rooms, id: \.self) { r in
                                Button(r) { draft.room = r; runCheck() }.buttonStyle(.bordered).controlSize(.small)
                                    .disabled(check.running)
                            }
                        }
                    }
                }
                Button(String(localized: "检查连接")) { runCheck() }.disabled(!draft.isComplete || check.running)
            }
            Section {
                Button(mode == .onboarding ? String(localized: "继续") : String(localized: "保存")) { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!draft.isComplete || draft.port <= 0 || draft.port > 65535 || (mode == .onboarding && !check.passed))
                    .listRowBackground(Color.clear)
                if mode == .onboarding {
                    Button(String(localized: "稍后再说")) { save() }
                        .frame(maxWidth: .infinity)
                        .disabled(!draft.isComplete)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.grouped.ignoresSafeArea())
        .navigationTitle(mode == .settings ? String(localized: "频道") : "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            if Demo.active { check.showDemoPass(); return }
            #endif
            if draft.isComplete { runCheck() }
        }
        .onDisappear {
            // A check points the bridge at the draft; leaving without saving points it back.
            if !saved { Tailnet.shared.apply(ChannelSettings.load()) }
        }
    }

    @State private var saved = false

    private func runCheck() { check.run(draft) }

    private func save() {
        saved = true
        model.save(draft)
        if let onDone { onDone() } else { dismiss() }
    }
}

/// The live checklist: Tailscale → `/healthz` → `/api/state` (design §4.1 step 2).
@MainActor
final class ConnectionCheck: ObservableObject {
    struct Item: Identifiable {
        enum State { case pending, running, ok, failed }
        let id: Int
        var text: String
        var state: State
    }

    @Published var items: [Item] = [
        .init(id: 0, text: "Tailscale", state: .pending),
        .init(id: 1, text: String(localized: "频道"), state: .pending),
        .init(id: 2, text: String(localized: "房间"), state: .pending),
    ]
    @Published var rooms: [String] = []
    @Published var running = false
    var passed: Bool { items.allSatisfy { $0.state == .ok } }
    /// Only the latest run writes results; an earlier one still in flight is ignored.
    private var generation = 0

    func run(_ s: ChannelSettings) {
        generation += 1
        let gen = generation
        running = true
        rooms = []
        items = [.init(id: 0, text: "Tailscale", state: .running),
                 .init(id: 1, text: String(localized: "频道"), state: .pending),
                 .init(id: 2, text: String(localized: "房间「\(s.room)」"), state: .pending)]
        Tailnet.shared.apply(s)
        let tuning = PocketTuning.load()
        Task {
            let up: Bool = await Task.detached { (try? Tailnet.shared.up(timeout: tuning.connectTimeout)) != nil }.value
            guard gen == generation else { return }
            items[0] = .init(id: 0, text: up ? String(localized: "Tailscale 已连接") : String(localized: "Tailscale 没有连上"), state: up ? .ok : .failed)
            guard up else { running = false; return }
            items[1].state = .running
            let client = ChannelClient(settings: s, tuning: tuning)
            do {
                let ms = try await client.health()
                guard gen == generation else { return }
                items[1] = .init(id: 1, text: String(localized: "频道可达 · \(ms) ms"), state: .ok)
            } catch {
                guard gen == generation else { return }
                items[1] = .init(id: 1, text: String(localized: "频道不可达：\(String(describing: error))"), state: .failed)
                running = false
                return
            }
            items[2].state = .running
            do {
                let result = try await client.state()
                guard gen == generation else { return }
                switch result {
                case .ok(let st):
                    var t = String(localized: "房间「\(st.roomName)」存在")
                    if st.daemonOK == true { t += String(localized: "，多多在线") } else if st.daemonOK == false { t += String(localized: "，多多暂时无法回复") }
                    if st.cerebellumOK == false { t += String(localized: "；语音服务不可用") }
                    items[2] = .init(id: 2, text: t, state: .ok)
                case .unknownRoom(let c):
                    rooms = c.rooms
                    items[2] = .init(id: 2, text: String(localized: "没有房间「\(s.room)」"), state: .failed)
                }
            } catch {
                guard gen == generation else { return }
                items[2] = .init(id: 2, text: String(localized: "房间检查失败：\(String(describing: error))"), state: .failed)
            }
            running = false
        }
    }
}

/// Tailscale's interactive login in an in-app browser session (design §4.1 step 1). The page
/// never redirects back to the app, so the session is closed when the node reports Running.
@MainActor
final class TailnetLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = TailnetLogin()
    private var session: ASWebAuthenticationSession?
    private var poll: Timer?

    func start(_ status: TailnetStatus) {
        guard session == nil else { return }
        guard let s = status.auth_url, let url = URL(string: s) else {
            // The node publishes the URL shortly after it starts; ask again.
            Tailnet.shared.start()
            return
        }
        let sess = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            Task { @MainActor in self?.finish() }
        }
        sess.presentationContextProvider = self
        sess.prefersEphemeralWebBrowserSession = false
        session = sess
        sess.start()
        poll = Timer.scheduledTimer(withTimeInterval: AppModel.refreshSeconds, repeats: true) { [weak self] _ in
            let login = self
            Task { @MainActor in
                let st = await Task.detached { Tailnet.shared.status() }.value
                if st.backend_state == "Running" { login?.session?.cancel(); login?.finish() }
            }
        }
    }

    /// Runs once: the poll and the session's completion handler can both end the login.
    private func finish() {
        guard session != nil || poll != nil else { return }
        poll?.invalidate()
        poll = nil
        session = nil
        AppLog.shared.log("tailnet_login_closed", ["state": Tailnet.shared.status().backend_state])
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
