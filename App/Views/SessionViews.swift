// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The left drawer (devices with the `sessions` scope): the bound room pinned at the top, then
/// the daemon's chat sessions and jobs. Tapping one opens it read-only in place of the thread.
struct SessionDrawer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var viewer: SessionViewer
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        let st = viewer.state
        VStack(alignment: .leading, spacing: 0) {
            Button { viewer.showRoom() } label: {
                DrawerRow(icon: "house", title: model.settings.roomTitle, detail: String(localized: "这台手机的房间"),
                          selected: st.openKey == nil, running: false)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let e = st.error {
                        Text(e == .forbidden ? String(localized: "这台手机没有查看会话的权限")
                             : String(localized: "暂时读不到多多的会话，正在重试"))
                            .font(.footnote).foregroundStyle(Palette.attention)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    } else if !st.listed {
                        ProgressView().frame(maxWidth: .infinity).padding(20)
                    } else if st.sessions.isEmpty {
                        Text(String(localized: "没有其他会话")).font(.footnote).foregroundStyle(Palette.tertiary)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    group(String(localized: "会话"), st.chats, open: st.openKey)
                    group(String(localized: "任务"), st.jobs, open: st.openKey)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.cell.ignoresSafeArea())
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [SessionSummary], open: String?) -> some View {
        if !items.isEmpty {
            let expanded = expandedGroups.contains(title)
            // Running first, then the latest activity; the rest fold so both groups stay in view.
            let shown = expanded ? items : Array(items.prefix(Self.foldAfter))
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(shown) { s in
                Button { viewer.open(s.key) } label: {
                    DrawerRow(icon: s.group == .chat ? "bubble.left" : "clock.arrow.circlepath", title: s.name,
                              detail: detail(s), selected: s.key == open, running: s.running)
                }
                .buttonStyle(.plain)
            }
            if items.count > Self.foldAfter {
                Button {
                    if expanded { expandedGroups.remove(title) } else { expandedGroups.insert(title) }
                } label: {
                    Text(expanded ? String(localized: "收起") : String(localized: "更多 \(items.count - Self.foldAfter) 个"))
                        .font(.caption).foregroundStyle(Palette.brand)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Rows a group shows before 「更多」. User decision.
    static let foldAfter = 5

    /// 「飞书 · 18:01」: where the session lives, then its last activity.
    private func detail(_ s: SessionSummary) -> String {
        [sourceName(s), s.lastEvent.map(activityText)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct DrawerRow: View {
    var icon: String
    var title: String
    var detail: String?
    var selected: Bool
    var running: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(Palette.brand).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Palette.text).lineLimit(1)
                if let detail { Text(detail).font(.caption2).foregroundStyle(Palette.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if running {
                Circle().fill(Palette.ok).frame(width: 7, height: 7)
                    .accessibilityLabel(String(localized: "正在运行"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.brandWash : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Last activity: the time today, else the date.
private func activityText(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? hm(d) : d.formatted(.dateTime.month().day())
}

/// An opened session, read-only: its recent rows as the daemon holds them, then live rows.
struct SessionThreadView: View {
    @ObservedObject var viewer: SessionViewer
    /// The foldable's session pane closes by a swipe toward the edge it leaves by: leading in
    /// landscape, down (past the top of the list) in portrait.
    var onSwipeLeading: (() -> Void)?
    var onPullDown: (() -> Void)?
    private static let bottomID = "session-bottom"
    private static let readingWidth: CGFloat = 640
    /// A swipe closes the pane when it would carry this far. Display only, tuned by hand on the
    /// iPhone Duo simulator.
    static let swipeToClose: CGFloat = 160
    /// Pulling the list down this far past its top closes the pane. Display only, as above.
    static let pullToClose: CGFloat = 90

    var body: some View {
        let st = viewer.state
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if st.error == .unavailable {
                        Text(String(localized: "暂时读不到多多的会话，正在重试"))
                            .font(.caption).foregroundStyle(Palette.attention).padding(8)
                    }
                    if !st.loaded {
                        ProgressView().padding(24)
                    } else if st.items.isEmpty {
                        Text(String(localized: "最近没有活动")).font(.subheadline).foregroundStyle(Palette.tertiary).padding(24)
                    }
                    ForEach(SessionDisplayItem.fold(st.items)) { item in
                        SessionItemView(item: item, openKey: st.openKey, sessions: st.sessions).id(item.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                // A readable column on a wide display (iPhone Duo's inner screen); the full width
                // on a phone.
                .frame(maxWidth: Self.readingWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                // Inside the scroll view: outside it, the scroll view's pan takes the drag first.
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { v in
                    guard let close = onSwipeLeading, abs(v.translation.width) > abs(v.translation.height),
                          -v.predictedEndTranslation.width > Self.swipeToClose else { return }
                    withAnimation(.smooth(duration: 0.4)) { close() }
                }, isEnabled: onSwipeLeading != nil)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(PullToClose(action: onPullDown))
            .onChange(of: st.items.count) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }
}

/// Calls `action` when the list is pulled down past its top by `SessionThreadView.pullToClose`.
private struct PullToClose: ViewModifier {
    var action: (() -> Void)?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let action {
            content.onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top < -SessionThreadView.pullToClose
            } action: { _, past in
                if past { withAnimation(.smooth(duration: 0.4)) { action() } }
            }
        } else {
            content
        }
    }
}

private struct SessionItemView: View {
    let item: SessionDisplayItem
    let openKey: String?
    let sessions: [SessionSummary]

    var body: some View {
        switch item {
        case .gap:
            Text(String(localized: "此处有未显示的事件"))
                .font(.caption2).foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        case .steps(_, let rows):
            SessionSteps(rows: rows)
        case .row(let r):
            switch r.kind {
            case .message:
                if !(r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MineBubble(text: r.text ?? "", voiceSource: nil, durationMs: nil, attachments: [],
                               meta: source(r.from).map { .plain(String(localized: "来自「\($0)」")) }, dimmed: false)
                }
            case .reply:
                ReplyBubble(text: r.text ?? "", at: r.date)
            case .notify:
                NotifyCard(text: r.text ?? "", from: r.fromLabel ?? source(r.from), at: r.date)
            case .tool:
                SessionSteps(rows: [r])
            case .system:
                Text(r.text ?? "")
                    .font(.caption2).foregroundStyle(Palette.tertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
        }
    }

    /// The sending session by its name in the list; nothing when the session sent it to itself.
    private func source(_ key: String?) -> String? {
        guard let key, key != openKey else { return nil }
        if let s = sessions.first(where: { $0.key == key }) { return s.name }
        // Not listed: the readable part of the key (`job:<name>.<hash>`, `<source>:<name>:…`).
        if key.hasPrefix("job:") {
            let id = key.dropFirst("job:".count)
            return id.lastIndex(of: ".").map { String(id[..<$0]) } ?? String(id)
        }
        let parts = key.split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : key
    }
}

/// A notification that entered the session, from another session or a device: a card with a
/// bell, never a chat bubble, so it does not read as part of a conversation.
private struct NotifyCard: View {
    var text: String
    var from: String?
    var at: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill").font(.caption2)
                Text(from.map { String(localized: "通知 · 来自「\($0)」") } ?? String(localized: "通知"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let at { Text(hm(at)).monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(Palette.notice)
            Text(text).font(.subheadline).foregroundStyle(Palette.text).textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.notice.opacity(0.45)))
        .accessibilityElement(children: .combine)
    }
}

/// Where a session lives, for the drawer and the notify bar: 飞书, 房间, nothing for a job.
func sourceName(_ s: SessionSummary) -> String? {
    switch s.source {
    case .feishu: String(localized: "飞书")
    case .room: String(localized: "房间")
    case .job: nil
    case .other(let prefix): prefix.isEmpty ? nil : prefix
    }
}

/// Under a session that takes notifications, in place of the room's composer: one bar that names
/// the target, 「🔔 给 main 发通知（飞书）」, and opens the notify sheet.
struct NotifyBar: View {
    @ObservedObject var viewer: SessionViewer
    let session: SessionSummary
    @State private var composing = false

    var body: some View {
        Button { composing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell")
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.notice)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.notice.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $composing) {
            NotifySheet(viewer: viewer, session: session)
                .presentationDetents([.medium])
        }
    }

    private var title: String {
        if let src = sourceName(session) { return String(localized: "给 \(session.name) 发通知（\(src)）") }
        return String(localized: "给 \(session.name) 发通知")
    }
}

/// Writing a notification: the target named in the title, what happens to it said once, text
/// only. Closes when the channel confirms delivery; a refusal stays on screen with its reason.
private struct NotifySheet: View {
    @ObservedObject var viewer: SessionViewer
    let session: SessionSummary
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let st = viewer.state
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "多多会在那个会话里处理这条通知"))
                    .font(.footnote).foregroundStyle(Palette.secondary)
                TextField(String(localized: "要告诉它什么"), text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cell))
                if case .failed(let reason) = st.notifyOutcome {
                    Text(failure(reason)).font(.footnote).foregroundStyle(Palette.attention)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(String(localized: "通知 \(session.name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if st.pendingNotify != nil {
                        ProgressView()
                    } else {
                        Button(String(localized: "发送")) { viewer.notify(text) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            viewer.clearNotifyOutcome()
            focused = true
        }
        .onChange(of: st.notifyOutcome) { _, outcome in
            if outcome == .sent { dismiss() }
        }
    }

    private func failure(_ r: NotifyFailure) -> String {
        switch r {
        case .forbidden: String(localized: "这台设备没有发通知的权限，需要重新配对")
        case .notNotifiable: String(localized: "这个会话不接收通知")
        case .notFound: String(localized: "多多那边已经没有这个会话了")
        case .failed: String(localized: "没有送到，请稍后再试")
        }
    }
}

/// Consecutive tool steps folded into one line, 「⌘ N 步 · 最后一步」, like a room turn's steps;
/// the chevron opens every step. A failed step shows in the line and in the list.
private struct SessionSteps: View {
    let rows: [SessionRow]
    @State private var open = false

    var body: some View {
        let failed = rows.contains(where: \.failed)
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: failed ? "exclamationmark.triangle" : "command").font(.caption2)
                    Text(rows.count == 1 ? rows[0].toolLine : String(localized: "\(rows.count) 步 · \(rows[rows.count - 1].toolLine)"))
                        .lineLimit(1).truncationMode(.tail)
                    if rows.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .font(.caption)
                .foregroundStyle(failed ? Palette.attention : Palette.tertiary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(rows.count == 1)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: r.failed ? "exclamationmark.triangle" : "command").font(.caption2)
                            Text(r.toolLine)
                        }
                        .font(.caption)
                        .foregroundStyle(r.failed ? Palette.attention : Palette.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.theirsFill.opacity(0.6)))
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A session's answer: Markdown like 多多's room answers, without the room's reply and read-aloud
/// actions (the viewer is read-only).
private struct ReplyBubble: View {
    var text: String
    var at: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownView(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(BubbleShape(mine: false, tail: true).fill(Palette.theirsFill))
                    .contextMenu {
                        Button { UIPasteboard.general.string = text } label: { Label(String(localized: "拷贝"), systemImage: "doc.on.doc") }
                        ShareLink(item: text) { Label(String(localized: "分享"), systemImage: "square.and.arrow.up") }
                    }
            }
            if let at { Text(hm(at)).font(.caption2).foregroundStyle(Palette.tertiary).padding(.horizontal, 6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
    }
}
