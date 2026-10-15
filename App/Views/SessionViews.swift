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
        let source: String? = switch s.source {
        case .feishu: String(localized: "飞书")
        case .room: String(localized: "房间")
        case .job: nil
        case .other(let prefix): prefix.isEmpty ? nil : prefix
        }
        return [source, s.lastEvent.map(activityText)].compactMap { $0 }.joined(separator: " · ")
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
    private static let bottomID = "session-bottom"
    private static let readingWidth: CGFloat = 640

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
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: st.items.count) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
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
