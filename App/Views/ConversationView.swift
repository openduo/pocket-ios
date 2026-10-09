// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The only root screen (design §3): inline nav bar, banner slot, thread, composer.
struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @State private var sheet: Sheet?
    @State private var bar = BarLayout()

    enum Sheet: String, Identifiable {
        case settings, passport
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.trying { TryBanner() }
                Banners()
                ZStack(alignment: .bottom) {
                    if model.chat.rows.isEmpty, model.chat.configured, !model.chat.hasHistory {
                        EmptyState(sheet: $sheet)
                    } else {
                        ThreadView()
                    }
                    if let t = model.toast {
                        ToastView(text: t)
                            .padding(.bottom, 12)
                            .task(id: t) {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                if model.toast == t { model.toast = nil }
                            }
                    }
                }
                Composer()
            }
            .background(Palette.background.ignoresSafeArea())
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { bar.centerX = $0 }
            .navigationTitle(String(localized: "多多"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { NavBar(sheet: $sheet, bar: $bar) }
        }
        .overlay { if model.holding { HoldOverlay() } }
        // The 按住说话 bar sits just above the home indicator. Deferring the bottom edge's system
        // gesture delivers a touch there at once instead of after iOS rules out a home swipe;
        // the cost is that going home from this screen takes a second swipe.
        .defersSystemGestures(on: .bottom)
        .sheet(item: $sheet) { s in
            switch s {
            case .settings: SettingsView()
            case .passport: PassportSheet().presentationDetents([.medium, .large])
            }
        }
        .fullScreenCover(isPresented: $model.ambientExpanded) { AmbientView() }
        .accessibilityAction(.magicTap) { HoldToggle.shared.magicTap(model) }
        .onAppear {
            #if DEBUG
            sheet = Demo.sheet
            Demo.runHoldProbe(model)
            #endif
        }
    }
}

// MARK: nav bar

/// Where the bar's side items end, so the centre item can be held to the width that stays centred.
struct BarLayout: Equatable {
    /// Space kept between the centre item and a side item's content; the side items draw their
    /// glass capsule around the content. Display only.
    static let sideGap: CGFloat = 12

    var centerX: CGFloat = 0
    var leadingMaxX: CGFloat = 0
    var trailingMinX: CGFloat = .infinity

    /// Widest centre item that is centred on the bar and clears both sides; nil until measured.
    var centreWidth: CGFloat? {
        guard centerX > 0, trailingMinX.isFinite else { return nil }
        return max(0, 2 * (min(centerX - leadingMaxX, trailingMinX - centerX) - Self.sideGap))
    }
}

/// Standard inline bar: settings leading; 多多 with the live state as a subtitle; Passport chip and
/// ambient trailing. The live state is text, so no avatar here (design §2). UIKit moves a centre
/// item that does not fit between the side items off centre, so the item is as wide as 多多
/// alone; the subtitle is drawn under it, centred and truncated to clear the side items
/// (`BarLayout`).
struct NavBar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @Binding var sheet: ConversationView.Sheet?
    @Binding var bar: BarLayout

    var body: some ToolbarContent {
        let p = model.presence
        ToolbarItem(placement: .topBarLeading) {
            Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(String(localized: "设置"))
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { bar.leadingMaxX = $0 }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(String(localized: "多多")).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
                // The subtitle row takes its height but no width; the text is drawn over it.
                subtitle(p.subtitle).frame(width: 1).hidden()
                    .overlay {
                        if let w = bar.centreWidth {
                            subtitle(p.subtitle).frame(width: w)
                        } else {
                            subtitle(p.subtitle).fixedSize()
                        }
                    }
                    .foregroundStyle(p.live ? Palette.brand : (model.chat.connection == .offline ? Palette.attention : Palette.secondary))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "多多，\(p.subtitle)"))
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .passport } label: { PassportChip() }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { bar.trailingMinX = $0 }
            AmbientButton()
        }
    }
}

private func subtitle(_ s: String) -> some View {
    Text(s).font(.caption).lineLimit(1).truncationMode(.tail)
}

struct AvatarView: View {
    var pose: Pose
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        pose.image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Palette.hairline, lineWidth: 0.5))
            .id(pose)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pose)
            .accessibilityHidden(true)
    }
}

struct PassportChip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let d = model.device
        HStack(spacing: 5) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Image(systemName: "candybarphone").font(.caption)
            Text(label).font(.footnote.monospacedDigit())
        }
        .foregroundStyle(Palette.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Passport，\(label)"))
        .accessibilityAddTraits(.isButton)
        .opacity(d.deviceName == nil && d.link == .scanning ? 0.8 : 1)
    }

    private var dotColor: Color {
        switch model.device.link {
        case .ready: model.device.versionError == nil ? Palette.ok : Palette.attention
        case .pairing, .connecting, .connected: Palette.tertiary
        default: Palette.placeholder
        }
    }

    private var label: String {
        let d = model.device
        if d.versionError != nil { return String(localized: "版本不匹配") }
        switch d.link {
        case .ready: return d.battery.map { "\($0)%" } ?? String(localized: "已连接")
        case .off: return String(localized: "蓝牙关闭")
        case .unauthorized: return String(localized: "无权限")
        case .scanning: return UserDefaults.standard.string(forKey: Keys.savedPeripheral) == nil ? String(localized: "未配对") : String(localized: "未连接")
        default: return String(localized: "未连接")
        }
    }
}

struct AmbientButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            if model.ambient.isOn { model.ambientExpanded = true } else if model.voiceAvailable { model.toggleAmbient() } else {
                model.toast = String(localized: "语音服务暂不可用")
            }
        } label: {
            // On: filled, and the tap opens the call view instead of toggling.
            Image(systemName: model.ambient.isOn ? "waveform.circle.fill" : "waveform")
        }
        .opacity(model.voiceAvailable ? 1 : 0.4)
        .accessibilityLabel(model.ambient.isOn ? String(localized: "环境模式，已开，打开通话界面") : String(localized: "打开环境模式"))
    }
}

// MARK: banners

struct Banners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if model.tailnet.backend_state == "NeedsLogin" || model.tailnet.backend_state == "NeedsMachineAuth" {
                Banner(icon: "lock.shield", title: String(localized: "需要重新登录 Tailscale"), detail: nil, action: String(localized: "登录")) {
                    TailnetLogin.shared.start(model.tailnet)
                }
            } else if model.chat.connection == .offline {
                Banner(icon: "wifi.slash", title: String(localized: "连不上多多"), detail: cachedText, action: String(localized: "重试")) {
                    PocketEngine.shared.connectionLost()
                }
            } else if model.chat.room?.daemonOK == false {
                Banner(icon: "moon.zzz", title: String(localized: "多多暂时无法回复"), detail: String(localized: "消息会先记下"), action: nil, onAction: nil)
            }
            if model.ambient.isOn { AmbientPill() }
        }
        .padding(.horizontal, 10)
        // Same gap below as above: the thread's scroll view starts under the slot, so without it
        // a row scrolled to the top edge is cut flush against the pill.
        .padding(.vertical, (model.ambient.isOn || bannerShown) ? 8 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.ambient.isOn)
    }

    private var bannerShown: Bool {
        model.tailnet.backend_state.hasPrefix("Needs") || model.chat.connection == .offline || model.chat.room?.daemonOK == false
    }

    private var cachedText: String {
        guard let t = model.chat.cachedAt else { return String(localized: "显示的是缓存的记录，连上后会自动补齐。") }
        return String(localized: "显示的是 \(hm(t)) 缓存的记录，连上后会自动补齐。")
    }
}

struct Banner: View {
    var icon: String
    var title: String
    var detail: String?
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail { Text(detail).font(.caption) }
            }
            Spacer(minLength: 4)
            if let action, let onAction {
                Button(action, action: onAction).font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(Palette.attention)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.attentionFill))
        .accessibilityElement(children: .combine)
    }
}

struct ToastView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.cell).shadow(color: .black.opacity(0.12), radius: 8, y: 2))
            .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}

// MARK: empty state

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 40)
                AvatarView(pose: model.presence.pose, size: 116)
                Text(String(localized: "我在，随时说")).font(.title2.weight(.semibold)).foregroundStyle(Palette.text)
                Text(String(localized: "打字、按住说话，或者打开环境模式让我一直听着。"))
                    .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    card("mic", String(localized: "按住下方的按钮说话"), String(localized: "松开就发出，手指移出按钮取消"))
                    card("waveform", String(localized: "环境模式"), String(localized: "手机变成一个会听会说的多多")) { model.toggleAmbient() }
                    if model.device.link != .ready {
                        card("candybarphone", String(localized: "添加 Passport"), String(localized: "口袋里按住 OK 键说话")) { sheet = .passport }
                    }
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 28)
        }
    }

    /// A card with an action is a button; without one it is a plain hint (the hold-to-talk bar
    /// itself is the control).
    @ViewBuilder
    private func card(_ icon: String, _ title: String, _ detail: String, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) { cardBody(icon, title, detail) }.buttonStyle(.plain)
        } else {
            cardBody(icon, title, detail).accessibilityElement(children: .combine)
        }
    }

    private func cardBody(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Palette.brandWash))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                Text(detail).font(.caption).foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.theirsFill))
    }
}

/// Always visible while trying: the content is prepared, not DuoDuo's own.
struct TryBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").accessibilityHidden(true)
            Text(String(localized: "体验模式 · 演示数据，不连接网络")).font(.footnote.weight(.semibold))
            Spacer(minLength: 4)
            Button(String(localized: "退出体验")) { model.stopTrying() }
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Palette.brand)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.brandWash)
    }
}
