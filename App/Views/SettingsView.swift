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
    @AppStorage(AudioPreferences.speakRepliesKey) private var speakReplies = false
    @AppStorage(AudioPreferences.keepAwakeKey) private var keepAwake = false

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
                    NavigationLink { ConnectionDetail() } label: {
                        row("link", Palette.brand, String(localized: "频道主机"), model.settings.host.isEmpty ? String(localized: "未配对") : model.settings.host)
                    }
                    NavigationLink { ConnectionDetail() } label: {
                        row("number", Palette.brand, String(localized: "房间"), model.settings.roomTitle, caption: roomCaption)
                    }
                    NavigationLink { TailscaleDetail() } label: {
                        row("shield.lefthalf.filled", Palette.ok, "Tailscale", tailnetText, stacked: true)
                    }
                } header: { Text(String(localized: "连接")) } footer: {
                    Text(String(localized: "主机和房间来自配对；换房间或换主机需要重新配对。多多随身只走你的 Tailscale 网络。"))
                }
                Section {
                    row("speaker.wave.2", Palette.attention, String(localized: "环境模式的声音"), model.ambient.isOn ? model.ambient.route : String(localized: "扬声器"))
                    Toggle(isOn: $speakReplies) { label("speaker.wave.2.bubble", Palette.secondary, String(localized: "播放语音回复")) }
                        .onChange(of: speakReplies) { _, _ in AmbientController.shared.audioWantChanged("setting") }
                    Toggle(isOn: $keepAwake) { label("sun.max", Palette.secondary, String(localized: "保持屏幕常亮")) }
                        .onChange(of: keepAwake) { _, on in
                            UIApplication.shared.isIdleTimerDisabled = on
                            PocketSurface.changed()
                        }
                    Toggle(isOn: $keepListening) { label("lock.iphone", Palette.secondary, String(localized: "离开 App 后继续听")) }
                    Toggle(isOn: $haptics) { label("hand.tap", Palette.secondary, String(localized: "按住说话的触感反馈")) }
                    Picker(selection: $headsetMic) {
                        Text(String(localized: "手机麦克风")).tag(false)
                        Text(String(localized: "AirPods 麦克风")).tag(true)
                    } label: {
                        label("airpodspro", Palette.secondary, String(localized: "连着 AirPods 时用"))
                    }
                } header: { Text(String(localized: "声音")) } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "播放语音回复：环境模式关着时，App 在前台就把多多的回复在这台手机上读出来；家里有设备在听时由那台设备播放。环境模式开着时，回复总会读出来，不想出声就在环境模式里点静音。保持屏幕常亮：App 在前台时屏幕不自动锁定，手机可以放着当音箱用。"))
                        Text(headsetMic
                             ? String(localized: "按住说话时 AirPods 切到通话模式，正在放的音乐音质会变差，松手后恢复。")
                             : String(localized: "按住说话用手机麦克风，AirPods 继续放声音，音质不变。"))
                    }
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

    /// The room's ID under its display name, when they differ. It is user data and is shown as
    /// entered, in any UI language.
    private var roomCaption: String? {
        model.settings.roomTitle == model.settings.room ? nil : model.settings.room
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

/// The paired connection, read-only: host, port, room, device. Changing any of it is pairing
/// again.
struct ConnectionDetail: View {
    @EnvironmentObject var model: AppModel
    @State private var pairing = false

    var body: some View {
        let s = model.settings
        List {
            Section {
                LabeledContent(String(localized: "主机"), value: s.host.isEmpty ? String(localized: "未配对") : s.host)
                LabeledContent(String(localized: "端口 · HTTPS"),
                               value: "\(s.port) · \(s.tls ? String(localized: "开") : String(localized: "关"))")
                LabeledContent(String(localized: "房间"), value: s.roomTitle)
                LabeledContent(String(localized: "会话查看"),
                               value: s.scope == .sessions ? String(localized: "可以") : String(localized: "不可以"))
            } footer: {
                if model.needsPairing {
                    Text(String(localized: "多多不再接受这台手机的配对，需要重新配对。")).foregroundStyle(Palette.attention)
                }
            }
            Section {
                Button(String(localized: "重新配对")) { pairing = true }
                    .disabled(model.trying)
            } footer: {
                Text(String(localized: "用新的配对链接重新配对。旧的配对由多多那边撤销。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.grouped.ignoresSafeArea())
        .navigationTitle(String(localized: "频道"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pairing) { PairingSheet(request: PairRequest()) }
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
