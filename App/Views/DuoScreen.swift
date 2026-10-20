// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The foldable's layouts other than the phone column (docs/design/iphone-duo.md). One order holds
/// in all of them: the room, then 多多, then an opened session. Opening a session pushes 多多 away
/// from it: right in landscape, up in portrait.
@available(iOS 27.1, *)
struct DuoScreen: View {
    let layout: DuoLayout
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
        switch layout {
        case .side(let split): SideScreen(split: split, viewer: viewer, sheet: $sheet)
        case .stacked(let top, let gap): StackedScreen(top: top, gap: gap, viewer: viewer, sheet: $sheet)
        case .tabletop(let top, let gap): TabletopScreen(top: top, gap: gap, viewer: viewer, sheet: $sheet)
        case .tent, .phone: TentScreen()
        }
    }
}

/// Open flat or as a book, landscape: 多多 beside the room. A session opens on the leading side
/// and pushes 多多 into the room's place. With ambient off there is no room and 多多 takes the
/// width. The bar sits on the trailing vertical strip.
@available(iOS 27.1, *)
private struct SideScreen: View {
    @EnvironmentObject var model: AppModel
    let split: CGFloat
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?
    @State private var bar = BarLayout()

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                let open = viewer.state.openKey != nil
                // The room stays beside 多多 with ambient off too: the mark and the last answer.
                let room = !open
                HStack(spacing: 0) {
                    if open {
                        SessionPane(viewer: viewer, exit: .leading)
                            .frame(width: split)
                            .transition(.move(edge: .leading))
                    }
                    ThreadColumn(sheet: $sheet)
                        .frame(width: open ? g.size.width - split : (room ? split : g.size.width))
                    if room {
                        RoomColumn()
                            .frame(width: g.size.width - split)
                            .transition(.move(edge: .trailing))
                    }
                }
                .clipped()
            }
            .background(Palette.background.ignoresSafeArea())
            .animation(.smooth(duration: 0.4), value: viewer.state.openKey)
            .animation(.snappy, value: model.ambient.isOn)
            .toolbar { NavBar(viewer: viewer, sheet: $sheet, bar: $bar, showsTitle: false, roomDrawn: viewer.state.openKey == nil) }
            .toolbar(removing: .title)
            .modifier(BarTitle())
        }
        .overlay { if viewer.state.drawerOpen { LeftDrawer(viewer: viewer) } }
        .animation(.easeOut(duration: 0.2), value: viewer.state.drawerOpen)
    }
}

/// Open flat, portrait: the room above 多多 while ambient is on, pushed up into a band by the
/// handle. A session rises from the bottom, pushes 多多 into the top half and folds the room into
/// its band. The keyboard covers the session rather than squeezing both halves: the composer sits
/// at the fold, above it.
@available(iOS 27.1, *)
private struct StackedScreen: View {
    @EnvironmentObject var model: AppModel
    let top: CGFloat
    let gap: CGFloat
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?
    @State private var bar = BarLayout()
    @State private var collapsed = false
    @State private var drag: CGFloat = 0
    @Environment(\.verticalBarInset) private var verticalBarInset

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                // The fold stays where it is below the navigation bar.
                let upper = max(0, top - g.frame(in: .named(Self.space)).minY)
                let lower = max(0, g.size.height - upper - gap)
                let open = viewer.state.openKey != nil
                let on = model.ambient.isOn
                VStack(spacing: 0) {
                    if on, open || collapsed {
                        RoomBand().transition(.move(edge: .top).combined(with: .opacity))
                        if !open { RoomHandle(collapsed: $collapsed, drag: $drag) }
                    } else if on {
                        BigRoom().frame(height: max(Self.minimumRoom, upper + min(0, drag)))
                        Color.clear.frame(height: gap)
                        RoomHandle(collapsed: $collapsed, drag: $drag)
                        RoomControls().padding(.bottom, 4)
                    }
                    ThreadColumn(sheet: $sheet).clipped()
                    if open {
                        Color.clear.frame(height: gap)
                        // The vertical bar has no title to name the session, so the pane does.
                        SessionPane(viewer: viewer, exit: .bottom, header: verticalBarInset != nil)
                            .frame(height: lower)
                            .transition(.move(edge: .bottom))
                    }
                }
                .ignoresSafeArea(.keyboard, edges: open ? .bottom : [])
                .overlay(alignment: .bottom) { if viewer.state.drawerOpen { BottomDrawer(viewer: viewer, height: lower) } }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { bar.centerX = $0 }
            }
            .background(Palette.background.ignoresSafeArea())
            .animation(.smooth(duration: 0.4), value: viewer.state.openKey)
            .animation(.snappy, value: collapsed)
            .animation(.snappy, value: model.ambient.isOn)
            .animation(.snappy, value: viewer.state.drawerOpen)
            .navigationTitle(String(localized: "多多"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { NavBar(viewer: viewer, sheet: $sheet, bar: $bar, sessionInBar: true, roomDrawn: model.ambient.isOn) }
            .modifier(BarTitle(opaque: true))
        }
        .coordinateSpace(.named(Self.space))
    }

    private static let space = "stacked"
    /// The room never drags shorter than this before it folds into the band. Display only.
    private static let minimumRoom: CGFloat = 120
}

/// Half-folded on a surface: the upright half only displays the room; everything touched is in
/// the lower half. A session rises from the bottom and pushes 多多 up behind the fold.
@available(iOS 27.1, *)
private struct TabletopScreen: View {
    @EnvironmentObject var model: AppModel
    let top: CGFloat
    let gap: CGFloat
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
        let open = viewer.state.openKey != nil
        VStack(spacing: 0) {
            BigRoom().frame(height: top)
            Color.clear.frame(height: gap)
            RoomControls {
                if model.sessionsEnabled {
                    if open {
                        AmbientControl(icon: "chevron.down", label: String(localized: "回到多多"), fill: Palette.chip, fg: Palette.text,
                                       size: 52) { withAnimation(.smooth(duration: 0.4)) { viewer.closeSession() } }
                    } else {
                        AmbientControl(icon: "line.3.horizontal", label: String(localized: "会话"), fill: Palette.chip, fg: Palette.text,
                                       size: 52) { withAnimation(.snappy) { viewer.openDrawer() } }
                    }
                }
            } trailing: {}
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            GeometryReader { g in
                Group {
                    if open {
                        SessionPane(viewer: viewer, exit: .bottom, header: true).transition(.move(edge: .bottom))
                    } else {
                        ThreadColumn(sheet: $sheet).transition(.move(edge: .top))
                    }
                }
                .overlay(alignment: .bottom) { if viewer.state.drawerOpen { BottomDrawer(viewer: viewer, height: g.size.height) } }
            }
            .clipped()
        }
        .background(Palette.background.ignoresSafeArea())
        .animation(.smooth(duration: 0.4), value: viewer.state.openKey)
        .animation(.snappy, value: viewer.state.drawerOpen)
    }
}

/// The outer display in landscape: the big room with its own controls; 对话 opens the thread.
@available(iOS 27.1, *)
private struct TentScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var thread = false

    var body: some View {
        BigRoom(controls: true) { thread = true }
            .background(Palette.background.ignoresSafeArea())
            .sheet(isPresented: $thread) {
                NavigationStack {
                    // The settings and Passport sheets open from the full screen, not from here.
                    ThreadColumn(sheet: .constant(nil))
                        .navigationTitle(String(localized: "多多"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button(String(localized: "完成")) { thread = false } }
                }
                .overlay { if model.holding { HoldOverlay() } }
            }
    }
}

/// An opened session in a pane: read-only, with the notify bar when it takes notifications. It
/// leaves by `exit`, and a swipe toward that edge closes it.
@available(iOS 27.1, *)
private struct SessionPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var viewer: SessionViewer
    var exit: Edge
    /// Off where the navigation bar already names the session.
    var header: Bool = false

    var body: some View {
        let close = { viewer.closeSession() }
        VStack(spacing: 0) {
            if exit == .bottom {
                Capsule().fill(Palette.placeholder).frame(width: 44, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
            if header || exit == .leading {
                HStack(spacing: 12) {
                    if exit == .leading {
                        // The same glass button as the navigation bar's back.
                        Button { withAnimation(.smooth(duration: 0.4)) { close() } } label: {
                            Image(systemName: "chevron.left").font(.body.weight(.medium)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .tint(Palette.text)
                        .accessibilityLabel(String(localized: "回到房间"))
                    }
                    SessionTitle(viewer: viewer).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            SessionThreadView(viewer: viewer,
                              onSwipeLeading: exit == .leading ? close : nil,
                              onPullDown: exit == .bottom ? close : nil)
            if model.notifyEnabled, let s = viewer.state.openSession, s.notify {
                NotifyBar(viewer: viewer, session: s)
            }
        }
        .background(Palette.cell.ignoresSafeArea())
    }
}

/// The session list rising from the bottom over the lower half; picking a row opens the session
/// in its place. The dimmed rest closes it.
@available(iOS 27.1, *)
private struct BottomDrawer: View {
    @ObservedObject var viewer: SessionViewer
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.18).ignoresSafeArea()
                .onTapGesture { viewer.closeDrawer() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(String(localized: "关闭会话列表"))
            SessionDrawer(viewer: viewer)
                .frame(height: height)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
        }
        .transition(.move(edge: .bottom))
    }
}

/// Drag up to fold the room into its band, down to open it again; a tap toggles.
@available(iOS 27.1, *)
private struct RoomHandle: View {
    @Binding var collapsed: Bool
    @Binding var drag: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(Palette.placeholder).frame(width: 44, height: 5)
            Text(collapsed ? String(localized: "下拉展开") : String(localized: "上推收起"))
                .font(.caption2).foregroundStyle(Palette.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { v in
                if v.translation.height < -Self.toggle { collapsed = true }
                if v.translation.height > Self.toggle { collapsed = false }
                drag = 0
            })
        .onTapGesture { collapsed.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collapsed ? String(localized: "展开房间") : String(localized: "收起房间"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { collapsed.toggle() }
    }

    /// A drag this long folds or unfolds the room. Display only.
    private static let toggle: CGFloat = 60
}
