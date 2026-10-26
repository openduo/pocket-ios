// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The foldable's layouts other than the phone column (docs/design/iphone-duo.md). Open flat, 多多
/// keeps its place (trailing in landscape, below in portrait) and a pane beside it shows the room,
/// the session list or an opened session.
@available(iOS 27.1, *)
struct DuoScreen: View {
    let layout: DuoLayout
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?

    var body: some View {
        switch layout {
        case .side: SideScreen(viewer: viewer, sheet: $sheet)
        case .stacked(let top, let gap): StackedScreen(top: top, gap: gap, viewer: viewer, sheet: $sheet)
        case .tabletop(let top, let gap): TabletopScreen(top: top, gap: gap, viewer: viewer, sheet: $sheet)
        case .tent, .phone: TentScreen()
        }
    }
}

/// Open flat or as a book, landscape: the pane on the leading side, 多多 on the trailing side as
/// on the outer display. The pane shows the room, the session list or an opened session; 多多
/// never moves. The bar sits on the trailing vertical strip.
///
/// The system arranges the two: as a book each takes one side of the fold, so 多多 keeps the outer
/// display's width; opening flat widens it to its share and plays the system's opening effect.
@available(iOS 27.1, *)
private struct SideScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var viewer: SessionViewer
    @Binding var sheet: ConversationView.Sheet?
    @State private var bar = BarLayout()

    var body: some View {
        NavigationStack {
            ArrangementView {
                PaneStack(viewer: viewer) { RoomColumn() }
                    .splitArrangementLayoutRatio(Self.paneShare)
            } secondary: {
                ThreadColumn(sheet: $sheet)
            }
            .arrangementViewStyle(.split)
            .background(Palette.background.ignoresSafeArea())
            .toolbar {
                NavBar(viewer: viewer, sheet: $sheet, bar: $bar, showsTitle: false, roomDrawn: PaneLevel(viewer.state) == .room,
                       paneList: { viewer.paneBack() })
            }
            .toolbar(removing: .title)
            .modifier(BarTitle())
        }
    }

    /// The pane's share of the width open flat; 多多 keeps the rest, a little more than the outer
    /// display. Display only (docs/constants.md).
    private static let paneShare: CGFloat = 0.4
}

/// Open flat, portrait: the pane above 多多, which stays below. The pane shows the room while
/// ambient is on (pushed up into a band by the handle), the session list or an opened session; with
/// ambient off and nothing opened there is no pane and 多多 takes the screen.
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

    var body: some View {
        NavigationStack {
            GeometryReader { g in
                // The fold stays where it is below the navigation bar.
                let upper = max(0, top - g.frame(in: .named(Self.space)).minY)
                let level = PaneLevel(viewer.state)
                let on = model.ambient.isOn
                VStack(spacing: 0) {
                    if on || level != .room {
                        PaneStack(viewer: viewer) {
                            VStack(spacing: 0) {
                                if collapsed {
                                    RoomBand()
                                    RoomHandle(collapsed: $collapsed, drag: $drag)
                                } else {
                                    BigRoom().frame(height: max(Self.minimumRoom, upper + min(0, drag)))
                                    Color.clear.frame(height: gap)
                                    RoomHandle(collapsed: $collapsed, drag: $drag)
                                    RoomControls().padding(.bottom, 4)
                                }
                            }
                        }
                        // The list and a session fill the upper half; the room sizes itself.
                        .frame(height: level == .room ? nil : upper)
                        if level != .room { Color.clear.frame(height: gap) }
                    }
                    // With a pane above it, the same fold treatment as tabletop: a hairline, and
                    // rows scroll out softly under it instead of being cut.
                    let pane = on || level != .room
                    ThreadColumn(sheet: $sheet)
                        .safeAreaBar(edge: .top, spacing: 0) {
                            if pane { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
                        }
                        .scrollEdgeEffectStyle(pane ? .soft : .automatic, for: .top)
                        .clipped()
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { bar.centerX = $0 }
            }
            .background(Palette.background.ignoresSafeArea())
            .animation(.snappy, value: collapsed)
            .animation(.snappy, value: model.ambient.isOn)
            // The pane takes the upper half for the list and a session; the room sizes itself.
            .animation(PaneLevel.slide, value: PaneLevel(viewer.state))
            .navigationTitle(String(localized: "多多"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavBar(viewer: viewer, sheet: $sheet, bar: $bar, roomDrawn: model.ambient.isOn && PaneLevel(viewer.state) == .room,
                       paneList: { viewer.paneBack() })
            }
            .modifier(BarTitle(opaque: true))
        }
        .coordinateSpace(.named(Self.space))
    }

    private static let space = "stacked"
    /// The room never drags shorter than this before it folds into the band. Display only.
    private static let minimumRoom: CGFloat = 120
}

/// What the foldable's pane shows: the room, the session list or an opened session, one level
/// deeper each.
enum PaneLevel: Int, Comparable {
    case room, list, session

    init(_ s: SessionViewerState) {
        self = s.openKey != nil ? .session : (s.drawerOpen ? .list : .room)
    }

    static func < (a: PaneLevel, b: PaneLevel) -> Bool { a.rawValue < b.rawValue }

    /// How the pane moves between levels.
    static var slide: Animation { .smooth(duration: slideSeconds) }
    static let slideSeconds = 0.35
}

/// The foldable's pane beside 多多: the room, the session list or a session, side by side on one
/// strip with deeper levels toward 多多 (trailing), as a phone pushes a page in from the right.
/// The strip slides to the level shown and going back reverses it; only the pane moves, 多多 does
/// not. The levels are fixed places, not views inserted and removed: there is no transition to
/// interrupt and nothing left behind over the shown level.
@available(iOS 27.1, *)
private struct PaneStack<Room: View>: View {
    @ObservedObject var viewer: SessionViewer
    @ViewBuilder var room: Room
    /// The session whose slide in has finished. Its rows are drawn from then on; while it slides
    /// in the pane shows the loading mark, so rows arriving meanwhile are not laid out mid-motion.
    @State private var settled: String?

    var body: some View {
        let level = PaneLevel(viewer.state)
        let st = viewer.state
        GeometryReader { g in
            ZStack {
                layer(.room, at: level, width: g.size.width) { room }
                layer(.list, at: level, width: g.size.width) { ListPane(viewer: viewer) }
                layer(.session, at: level, width: g.size.width) {
                    // A closed session's rows stay until the next one opens (`backToList`): the
                    // pane slides them out as they were, and nothing is torn down while it moves.
                    if st.shownKey != nil {
                        // A closed session keeps its rows on the way out.
                        SessionPane(viewer: viewer, exit: .trailing, back: { viewer.paneBack() },
                                    showsRows: st.openKey == nil || settled == st.openKey)
                            .environment(\.narrowPane, true)
                    }
                }
            }
        }
        // Cut the neighbouring levels at the sides only: backgrounds and rows run on under the
        // home indicator and the status bar, as 多多 does beside them.
        .mask { Rectangle().ignoresSafeArea(edges: .vertical) }
        .animation(PaneLevel.slide, value: level)
        .onAppear { settled = st.openKey }
        .onChange(of: st.openKey) { _, key in
            guard let key else { return }
            settled = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(PaneLevel.slideSeconds))
                guard viewer.state.openKey == key else { return }
                withAnimation { settled = key }
            }
        }
    }

    /// One level's place on the strip. Every level stays built, so a move only slides the strip;
    /// a level off screen is marked so its animations pause.
    private func layer<C: View>(_ rank: PaneLevel, at level: PaneLevel, width: CGFloat,
                                @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: CGFloat(rank.rawValue - level.rawValue) * width)
            .allowsHitTesting(rank == level)
            .accessibilityHidden(rank != level)
            .environment(\.offstage, rank != level)
    }
}

extension SessionViewer {
    /// Back from a session in the foldable's pane to the list.
    func paneBack() {
        withAnimation(PaneLevel.slide) { backToList() }
    }
}

/// The session list in the foldable's pane. It is the pane's list root: no ‹; the room row, the
/// sessions button and a swipe back toward the outer edge return to the room.
@available(iOS 27.1, *)
private struct ListPane: View {
    @ObservedObject var viewer: SessionViewer

    var body: some View {
        SessionDrawer(viewer: viewer, inPane: true)
            .modifier(SwipeBack(action: { viewer.showRoom() }))
    }
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
                .overlay(alignment: .bottom) { BottomDrawer(viewer: viewer, height: g.size.height) }
            }
            // The fold between the room and the conversation: a hairline, and rows scroll out
            // softly under it instead of being cut at the controls.
            .safeAreaBar(edge: .top, spacing: 0) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .scrollEdgeEffectStyle(.soft, for: .top)
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
    /// Where ‹ and the swipe go: the room thread unless given.
    var back: (() -> Void)?
    /// Off while the pane slides the session in: the loading mark stands in for the rows.
    var showsRows = true
    /// Off where the navigation bar already names the session.
    var header: Bool = false

    var body: some View {
        let close = back ?? { viewer.closeSession() }
        VStack(spacing: 0) {
            if exit == .bottom {
                Capsule().fill(Palette.placeholder).frame(width: 44, height: 5)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityHidden(true)
            }
            if header || exit == .trailing {
                HStack(spacing: 12) {
                    if exit == .trailing {
                        // The same glass button as the navigation bar's back.
                        Button(action: close) {
                            Image(systemName: "chevron.left").font(.body.weight(.medium)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .tint(Palette.text)
                        .accessibilityLabel(back == nil ? String(localized: "回到房间") : String(localized: "回到会话列表"))
                    }
                    SessionTitle(viewer: viewer).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            SessionThreadView(viewer: viewer, showsRows: showsRows,
                              onSwipeBack: exit == .trailing ? close : nil,
                              onPullDown: exit == .bottom ? close : nil)
            // The shown session: closing slides the pane out as it was, the bar included.
            if model.notifyEnabled, let s = viewer.state.shownSession, s.notify {
                NotifyBar(viewer: viewer, session: s)
            }
        }
        .background(Palette.cell.ignoresSafeArea())
    }
}

/// The session list rising from the bottom over the lower half while the drawer is open; picking
/// a row opens the session in its place. The list rises; the dimming fades in place, and a tap on
/// it closes the drawer.
@available(iOS 27.1, *)
private struct BottomDrawer: View {
    @ObservedObject var viewer: SessionViewer
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            if viewer.state.drawerOpen {
                DrawerScrim(viewer: viewer, opacity: 0.18)
                SessionDrawer(viewer: viewer)
                    .frame(height: height)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
                    .transition(.move(edge: .bottom))
            }
        }
        // Closed, the overlay is empty and lets every touch through.
        .allowsHitTesting(viewer.state.drawerOpen)
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
