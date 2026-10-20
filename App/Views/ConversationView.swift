// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The root screen. On a phone (and the closed foldable held upright): inline nav bar, banner slot,
/// thread, composer (design §3), with an opened session pushed over it. On the foldable's other
/// postures the room is drawn beside or above 多多 (`DuoScreen`, docs/design/iphone-duo.md).
struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var viewer = SessionViewer.shared
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var sheet: Sheet?
    /// The window's own top inset while the system shows a vertical bar (the foldable); nil
    /// without one.
    @State private var verticalBar: CGFloat?

    enum Sheet: String, Identifiable {
        case settings, passport
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { g in
            let layout = layout(g)
            Group {
                if layout != .phone, #available(iOS 27.1, *) {
                    DuoScreen(layout: layout, viewer: viewer, sheet: $sheet)
                } else {
                    PhoneScreen(viewer: viewer, sheet: $sheet)
                }
            }
            .environment(\.roomInline, layout.roomInline)
            .environment(\.verticalBarInset, verticalBar)
            // The call view belongs to the phone layout; the others draw the room themselves.
            .onChange(of: layout.roomInline, initial: true) { _, inline in if inline { model.ambientExpanded = false } }
        }
        .overlay { if model.holding { HoldOverlay() } }
        .background {
            if #available(iOS 27.1, *) { VerticalBarProbe { verticalBar = $0 } }
        }
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
        // Losing the scope or the pairing closes the viewer; the room thread stays.
        .onChange(of: model.sessionsEnabled) { _, on in if !on { viewer.showRoom() } }
        .onAppear {
            #if DEBUG
            sheet = Demo.sheet
            Demo.runHoldProbe(model)
            #endif
        }
    }

    private func layout(_ g: GeometryProxy) -> DuoLayout {
        guard #available(iOS 27.1, *) else { return .phone }
        let f = g.reservedRegions(kind: .division).first(where: \.isActive)?.frame
        return DuoLayout.choose(regularWidth: widthClass == .regular, compactHeight: heightClass == .compact,
                                width: g.size.width, height: g.size.height,
                                fold: f.map { DuoLayout.Fold(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
    }
}

extension EnvironmentValues {
    /// The layout draws the room, so ambient mode opens no call view and shows no pill.
    @Entry var roomInline = false
    /// With the system's vertical bar at the trailing edge: the window's top inset, without the
    /// navigation bar's height. The navigation items go into the vertical bar. Nil without one.
    @Entry var verticalBarInset: CGFloat?
}

/// The live mark stands for the title in the vertical bar, so the top keeps no title band.
struct BarTitle: ViewModifier {
    /// The horizontal bar is drawn opaque in the page colour.
    var opaque = false
    @Environment(\.verticalBarInset) private var inset

    func body(content: Content) -> some View {
        // The vertical bar exists only from iOS 27.1.
        if let inset, #available(iOS 27.1, *) {
            // Hiding the navigation bar would take the vertical bar's items with it; the empty
            // horizontal bar stays and the content runs up under it to the window's own inset.
            // The empty bar's background would cover the content's first row.
            content.toolbar(removing: .title).toolbarBackground(.hidden, for: .navigationBar)
                .ignoresSafeArea(.container, edges: .top).padding(.top, inset)
        } else if opaque {
            content.toolbarBackground(Palette.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}

/// Reports whether the system places a vertical bar here. The edge is a trait with no SwiftUI
/// counterpart, so a plain view reads it and follows its changes.
@available(iOS 27.1, *)
private struct VerticalBarProbe: UIViewRepresentable {
    var onChange: (CGFloat?) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = onChange
        return v
    }

    func updateUIView(_ v: Probe, context: Context) { v.onChange = onChange }

    final class Probe: UIView {
        var onChange: ((CGFloat?) -> Void)?
        private var last: CGFloat??

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (v: Probe, _) in v.report() }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        // The window's inset changes with the posture and the orientation.
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let window else { return }
            let value: CGFloat? = traitCollection.verticalBarEdge != .unspecified ? window.safeAreaInsets.top : nil
            guard last != .some(value) else { return }
            last = .some(value)
            DispatchQueue.main.async { [onChange] in onChange?(value) }
        }
    }
}

/// 多多's thread as every layout shows it: banners, the thread or the empty state, a toast, and
/// the composer.
struct ThreadColumn: View {
    @EnvironmentObject var model: AppModel
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
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
    }
}

/// The phone: the room thread, and an opened session pushed over it with the system back.
private struct PhoneScreen: View {
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?
    @State private var bar = BarLayout()

    var body: some View {
        NavigationStack {
            ThreadColumn(sheet: $sheet)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { bar.centerX = $0 }
                .navigationTitle(String(localized: "多多"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { NavBar(viewer: viewer, sheet: $sheet, bar: $bar) }
                .modifier(BarTitle(opaque: true))
                .navigationDestination(isPresented: Binding(get: { viewer.state.openKey != nil },
                                                            set: { if !$0 { viewer.closeSession() } })) {
                    SessionPage(viewer: viewer)
                }
        }
        .overlay { if viewer.state.drawerOpen { LeftDrawer(viewer: viewer) } }
        .animation(.easeOut(duration: 0.2), value: viewer.state.drawerOpen)
    }
}

/// An opened session pushed on the phone: read-only, with the notify bar when it takes them.
private struct SessionPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var viewer: SessionViewer

    var body: some View {
        VStack(spacing: 0) {
            SessionThreadView(viewer: viewer)
            if model.notifyEnabled, let s = viewer.state.openSession, s.notify {
                NotifyBar(viewer: viewer, session: s)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .principal) { SessionTitle(viewer: viewer) } }
    }
}

/// The open session's name over 只读, or 只读 · 正在运行.
struct SessionTitle: View {
    @ObservedObject var viewer: SessionViewer

    var body: some View {
        let s = viewer.state.openSession
        let name = s?.name ?? viewer.state.openKey ?? ""
        let sub = s?.running == true ? String(localized: "只读 · 正在运行") : String(localized: "只读")
        VStack(spacing: 0) {
            Text(name).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
            Text(sub).font(.caption).foregroundStyle(s?.running == true ? Palette.brand : Palette.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The session list over the screen from the leading edge; the dimmed side closes it.
struct LeftDrawer: View {
    @ObservedObject var viewer: SessionViewer

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { viewer.closeDrawer() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(String(localized: "关闭会话列表"))
                SessionDrawer(viewer: viewer)
                    .frame(width: min(g.size.width * Self.share, Self.maxWidth))
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 4)
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// Drawer width: this share of the screen, up to the max, so the room behind stays visible
    /// as the way back. Display only.
    static let share: CGFloat = 0.82
    static let maxWidth: CGFloat = 340
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
/// ambient trailing. The live state is text, so no mark here (design §2). UIKit moves a centre
/// item that does not fit between the side items off centre, so the item is as wide as 多多
/// alone; the subtitle is drawn under it, centred and truncated to clear the side items
/// (`BarLayout`).
struct NavBar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?
    @Binding var bar: BarLayout
    /// Open flat in portrait the session opens below 多多 and the bar names it, with the way back.
    var sessionInBar = false
    /// Landscape on the foldable puts the bar on the trailing strip; the title would only leave an
    /// empty band at the top.
    var showsTitle = true
    /// The layout draws the room with its own mark and ambient controls; the bar leaves both out,
    /// so each appears once.
    var roomDrawn = false

    /// The opened session, when the bar names it.
    private var session: (name: String, running: Bool)? {
        guard sessionInBar, let key = viewer.state.openKey else { return nil }
        let s = viewer.state.openSession
        return (s?.name ?? key, s?.running ?? false)
    }

    @Environment(\.verticalBarInset) private var verticalBarInset

    var body: some ToolbarContent {
        if verticalBarInset != nil {
            if #available(iOS 27.1, *) {
                ToolbarItemGroup(placement: .topBarTrailing) { vertical }
                    .axisBehavior(.verticalPreferred)
            }
        } else {
            horizontal
        }
    }

    private var state: (mood: LogoMark.Mood, subtitle: String, live: Bool) {
        session.map { s in
            (mood: LogoMark.Mood.idle, subtitle: s.running ? String(localized: "只读 · 正在运行") : String(localized: "只读"), live: s.running)
        } ?? model.presence
    }

    /// The vertical bar: the live mark in place of the title, then every control once. The
    /// session's name moves into its pane.
    @ViewBuilder private var vertical: some View {
        let p = state
        if !roomDrawn {
            LogoMark(mood: p.mood)
                .frame(width: 40, height: 40)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: String(localized: "多多") + String(localized: "，") + p.subtitle))
                .accessibilityAddTraits(.isHeader)
        }
        if session != nil {
            Button { withAnimation(.smooth(duration: 0.4)) { viewer.closeSession() } } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(String(localized: "回到房间"))
        } else if model.sessionsEnabled {
            Button { withAnimation(.snappy) { viewer.openDrawer() } } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel(String(localized: "会话列表"))
        }
        Button { sheet = .settings } label: { Image(systemName: "gearshape") }
            .accessibilityLabel(String(localized: "设置"))
        Button { sheet = .passport } label: { PassportChip(compact: true) }
        if !roomDrawn { AmbientButton() }
    }

    @ToolbarContentBuilder private var horizontal: some ToolbarContent {
        let p = state
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 16) {
                if session != nil {
                    Button { withAnimation(.smooth(duration: 0.4)) { viewer.closeSession() } } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel(String(localized: "回到房间"))
                } else if model.sessionsEnabled {
                    Button { withAnimation(.snappy) { viewer.openDrawer() } } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel(String(localized: "会话列表"))
                }
                Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(String(localized: "设置"))
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { bar.leadingMaxX = $0 }
        }
        if showsTitle { ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(session?.name ?? String(localized: "多多")).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
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
            .accessibilityLabel(Text(verbatim: (session?.name ?? String(localized: "多多")) + String(localized: "，") + p.subtitle))
            .accessibilityAddTraits(.isHeader)
        } }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .passport } label: { PassportChip() }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { bar.trailingMinX = $0 }
            if !roomDrawn { AmbientButton() }
        }
    }
}

private func subtitle(_ s: String) -> some View {
    Text(s).font(.caption).lineLimit(1).truncationMode(.tail)
}

struct PassportChip: View {
    @EnvironmentObject var model: AppModel
    /// Stacked for the vertical bar: the device with its dot, the label under it.
    var compact = false

    var body: some View {
        let d = model.device
        Group {
            if compact {
                VStack(spacing: 2) {
                    Image(systemName: "candybarphone").font(.body)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(dotColor).frame(width: 7, height: 7).offset(x: 4, y: -2)
                        }
                    Text(label).font(.caption2.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Image(systemName: "candybarphone").font(.caption)
                    Text(label).font(.footnote.monospacedDigit())
                }
            }
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
    @Environment(\.roomInline) private var roomInline

    var body: some View {
        Button { model.ambientTapped(expand: !roomInline) } label: {
            // On: filled. The tap opens the call view, or turns ambient off where the room is
            // drawn inline.
            Image(systemName: model.ambient.isOn ? "waveform.circle.fill" : "waveform")
        }
        .opacity(model.voiceAvailable ? 1 : 0.4)
        .accessibilityLabel(model.ambient.isOn
                            ? (roomInline ? String(localized: "环境模式，已开，关闭") : String(localized: "环境模式，已开，打开通话界面"))
                            : String(localized: "打开环境模式"))
    }
}

// MARK: banners

struct Banners: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.roomInline) private var roomInline

    var body: some View {
        VStack(spacing: 8) {
            switch model.chat.upgrade {
            case .appUpdate:
                Banner(icon: "arrow.down.app", title: String(localized: "多多随身需要更新"),
                       detail: String(localized: "家里的 ambient 已升级，这个版本连不上它"), action: String(localized: "更新")) {
                    UIApplication.shared.open(AppLinks.signUp)
                }
            case .channelUpgrade:
                Banner(icon: "arrow.up.circle", title: String(localized: "家里的 ambient 需要升级"),
                       detail: String(localized: "按 ambient 部署文档 docs/deploy.md 的 Upgrading 一节升级"), action: nil, onAction: nil)
            case nil:
                EmptyView()
            }
            if model.needsPairing, !model.trying {
                Banner(icon: "key.slash", title: String(localized: "需要重新配对"),
                       detail: String(localized: "多多不再接受这台手机，请让多多生成新的配对链接"), action: String(localized: "配对")) {
                    model.pairSheet = PairRequest()
                }
            } else if model.tailnet.backend_state == "NeedsLogin" || model.tailnet.backend_state == "NeedsMachineAuth" {
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
            if pill { AmbientPill() }
        }
        .padding(.horizontal, 10)
        // Same gap below as above: the thread's scroll view starts under the slot, so without it
        // a row scrolled to the top edge is cut flush against the pill.
        .padding(.vertical, (pill || bannerShown) ? 8 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.ambient.isOn)
    }

    /// Minimised ambient, where the layout does not draw the room.
    private var pill: Bool { model.ambient.isOn && !roomInline }

    private var bannerShown: Bool {
        model.chat.upgrade != nil || model.needsPairing || model.tailnet.backend_state.hasPrefix("Needs") || model.chat.connection == .offline || model.chat.room?.daemonOK == false
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
    @Environment(\.roomInline) private var roomInline
    @Environment(\.verticalBarInset) private var verticalBarInset
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 40)
                // Only where nothing else on screen carries the mark (the room, the vertical bar).
                if !roomInline, verticalBarInset == nil {
                    LogoMark(mood: model.presence.mood).frame(width: 150, height: 150)
                }
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

/// Links the app opens. The update banner opens the TestFlight sign-up form the README links.
enum AppLinks {
    static let signUp = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSfIUllzEsHU18l3q_K1SBo8FBx-GztPhzUKotWpp74mYAIH-A/viewform")!
}
