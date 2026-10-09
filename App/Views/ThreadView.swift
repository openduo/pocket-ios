// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    /// The end of the thread is on screen (or within the rows the lazy stack keeps built).
    @State private var atBottom = true
    private static let bottomID = "thread-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    OlderHeader()
                    ForEach(model.chat.rows) { row in
                        RowView(row: row).id(row.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // The bottom anchor alone is not enough: when a row changes height, the lazy stack
            // re-estimates rows it has not built and its kept offset can point past them, leaving
            // the thread blank. While the reader is at the end, every change scrolls to the end
            // row after layout, which builds the rows there.
            .onChange(of: model.chat.rows) { _, _ in
                guard atBottom else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // The bottom anchor keeps the newest row in view, so a row that grows pushes its own
            // top upwards; an opened step list is brought back to the top of the screen.
            .environment(\.revealRow) { id in
                atBottom = false
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }
}

private struct RevealRowKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Scrolls the thread so the row with this id starts at the top.
    var revealRow: ((String) -> Void)? {
        get { self[RevealRowKey.self] }
        set { self[RevealRowKey.self] = newValue }
    }
}

/// Top of the thread: walks the room log backwards one day at a time (design §8).
struct OlderHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.chat.older {
            case .loading:
                ProgressView().padding(8)
            case .exhausted(let before):
                Button(String(localized: "\(before) 之前 \(ConversationStore.historyScanDays) 天没有记录 · 继续找")) {
                    ConversationStore.shared.loadOlder()
                }
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .padding(8)
            case .idle:
                if model.chat.connection == .online, model.chat.hasHistory {
                    Color.clear.frame(height: 1).onAppear { ConversationStore.shared.loadOlder() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct RowView: View {
    let row: ThreadRow

    var body: some View {
        switch row {
        case .separator(_, let label):
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .mine(let m):
            MineBubble(text: m.text, voiceSource: m.voiceSource, durationMs: m.durationMs, attachments: m.attachments,
                       meta: m.delivery.map { .plain($0) }, dimmed: false)
        case .duoduo(let d):
            DuoduoBubble(rowID: row.id, text: d.text, at: d.at, spoken: d.spoken, showTime: d.showTime, trace: d.trace,
                         attachments: d.attachments)
        case .heard(let h):
            HeardFold(heard: h)
        case .pending(let p):
            PendingRow(item: p)
        case .working(let w):
            WorkingBubble(working: w)
        case .provisional(let p, _):
            DuoduoBubble(rowID: row.id, text: p.text, at: p.at, spoken: nil, showTime: true, trace: p.trace)
        }
    }
}

// MARK: bubbles

enum Meta: Equatable {
    case plain(String)
    case attention(String)
    case progress(String)
}

struct MineBubble: View {
    var text: String
    var voiceSource: String?
    var durationMs: Int?
    var attachments: [ChannelAttachment]
    var meta: Meta?
    var dimmed: Bool
    var failed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(attachments, id: \.self) { a in
                AttachmentView(attachment: a, mine: true)
            }
            if !text.isEmpty || voiceSource != nil {
                HStack(spacing: 8) {
                    if failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Palette.attention)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let voiceSource {
                            HStack(spacing: 4) {
                                Image(systemName: voiceSource == "passport" ? "candybarphone" : "mic.fill")
                                Text(voiceHead(voiceSource))
                            }
                            .font(.caption)
                            .opacity(0.75)
                        }
                        if text.isEmpty, voiceSource != nil {
                            VoiceGlyph().frame(width: 96, height: 16)
                        }
                        let parts = UserQuote.split(text)
                        if let q = parts.quote {
                            QuoteLine(text: q)
                        }
                        if !parts.text.isEmpty {
                            Text(linkified(parts.text))
                                .font(.body)
                                .tint(Palette.mineText)
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(Palette.mineText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(BubbleShape(mine: true, tail: true).fill(Palette.mineFill))
                    .opacity(dimmed ? 0.6 : 1)
                    .contextMenu {
                        Button { UIPasteboard.general.string = text } label: { Label(String(localized: "拷贝"), systemImage: "doc.on.doc") }
                        ShareLink(item: text) { Label(String(localized: "分享"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
            if let meta { MetaLine(meta: meta) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    private func voiceHead(_ src: String) -> String {
        let name = src == "passport" ? "Passport" : String(localized: "语音")
        return durationMs.map { "\(name) · \(durationText($0))" } ?? name
    }

    private var a11yLabel: String {
        var parts = [String(localized: "我")]
        if let v = voiceSource { parts.append(v == "passport" ? String(localized: "Passport 语音") : String(localized: "语音")) }
        if let d = durationMs { parts.append(String(localized: "\(Int((Double(d) / 1000).rounded())) 秒")) }
        if !attachments.isEmpty { parts.append(String(localized: "\(attachments.count) 个附件")) }
        parts.append(text)
        if case .attention(let s) = meta { parts.append(s) }
        return parts.joined(separator: String(localized: "，"))
    }
}

struct MetaLine: View {
    var meta: Meta
    var body: some View {
        HStack(spacing: 4) {
            switch meta {
            case .plain(let s): Text(s).foregroundStyle(Palette.tertiary)
            case .attention(let s):
                Image(systemName: "exclamationmark.circle.fill")
                Text(s)
            case .progress(let s):
                ProgressView().controlSize(.mini)
                Text(s).foregroundStyle(Palette.tertiary)
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.attention)
        .padding(.horizontal, 4)
    }
}

struct DuoduoBubble: View {
    @EnvironmentObject var model: AppModel
    var rowID: String
    var text: String
    var at: Date?
    var spoken: String?
    var showTime: Bool
    var trace: TurnState.Trace
    /// Files 多多 sent: images inline (tap to view), other files as cards (Quick Look).
    var attachments: [ChannelAttachment] = []

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Outside the bubble: the bubble's long-press menu must not sit over the toggle.
            if !trace.steps.isEmpty {
                TraceStrip(trace: trace, rowID: rowID)
            }
            ForEach(attachments, id: \.self) { a in
                AttachmentView(attachment: a, mine: false)
            }
            if hasText {
                MarkdownView(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(BubbleShape(mine: false, tail: true).fill(Palette.theirsFill))
                    .contextMenu {
                        Button {
                            model.voiceInput = false
                            model.quote = text
                        } label: { Label(String(localized: "回复"), systemImage: "arrowshape.turn.up.left") }
                        Button { UIPasteboard.general.string = text } label: { Label(String(localized: "拷贝"), systemImage: "doc.on.doc") }
                        ShareLink(item: text) { Label(String(localized: "分享"), systemImage: "square.and.arrow.up") }
                    }
            }
            if showTime, at != nil || spoken != nil {
                HStack(spacing: 6) {
                    if let at { Text(hm(at)) }
                    if let spoken { Text("· " + spoken) }
                }
                .font(.caption2)
                .foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
        // The step toggle and files stay their own elements so VoiceOver can open them.
        .accessibilityElement(children: attachments.isEmpty && trace.steps.isEmpty ? .combine : .contain)
        .accessibilityLabel(String(localized: "多多\(at.map { String(localized: "，") + hm($0) } ?? "")\(attachments.isEmpty ? "" : String(localized: "，发来 \(attachments.count) 个附件"))：\(text)"))
    }
}

/// Overheard room speech, compact (decision Q6).
struct HeardFold: View {
    let heard: ThreadRow.Heard
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !heard.folded.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(open ? String(localized: "收起") : String(localized: "房间里还说了 \(heard.folded.count) 句"))
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                if open { ForEach(Array(heard.folded.enumerated()), id: \.offset) { _, l in line(l) } }
            }
            ForEach(Array(heard.lines.enumerated()), id: \.offset) { _, l in line(l) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func line(_ l: ThreadRow.Heard.Line) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if let s = l.speaker {
                Text(s)
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Palette.hairline))
            } else {
                Image(systemName: "ear").font(.caption2).foregroundStyle(Palette.tertiary)
            }
            Text(l.text).font(.footnote).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "房间里\(l.speaker.map { " \($0) " } ?? "")：\(l.text)"))
    }
}

struct PendingRow: View {
    let item: OutboxItem

    var body: some View {
        let text: String
        var voice: String?
        var duration: Int?
        var atts: [ChannelAttachment] = []
        switch item.body {
        case .text(let t, let a):
            text = t
            atts = a
        case .voice(_, let ms):
            voice = "phone"
            duration = ms
            if case .delivered(_, _, let tr, _) = item.state { text = tr ?? "" } else { text = "" }
        }
        let meta: Meta
        var dimmed = false
        switch item.state {
        case .queued:
            meta = .plain(String(localized: "等待连接，连上后发送"))
            dimmed = true
        case .sending:
            meta = .progress(item.isVoice ? String(localized: "正在识别…") : String(localized: "发送中"))
            dimmed = true
        case .failed(let reason):
            meta = .attention(reason)
        case .delivered(_, _, _, let recorded):
            meta = .plain(recorded ? String(localized: "已送达") : String(localized: "已送达，记录未保存"))
        }
        var failed = false
        if case .failed = item.state { failed = true }
        return MineBubble(text: text, voiceSource: voice, durationMs: duration, attachments: atts, meta: meta, dimmed: dimmed,
                          failed: failed)
            .onTapGesture {
                if case .failed = item.state { ConversationStore.shared.retry(item.id) }
            }
            .contextMenu {
                if case .failed = item.state {
                    Button { ConversationStore.shared.retry(item.id) } label: { Label(String(localized: "重试"), systemImage: "arrow.clockwise") }
                }
                if item.uttID == nil {
                    Button(role: .destructive) { ConversationStore.shared.delete(item.id) } label: {
                        Label(String(localized: "删除"), systemImage: "trash")
                    }
                }
            }
            .accessibilityAction(named: String(localized: "重试")) {
                // Only a failed item: retry re-queues, so a sent one would go out twice.
                if case .failed = item.state { ConversationStore.shared.retry(item.id) }
            }
    }
}

/// The tool steps of an answered turn, like the Feishu channel's finished process card: one line
/// above the answer, 「任务已完成 · N 步 · T」; the chevron opens every step. The list is the whole
/// trace, uncapped like the Feishu channel's archive; the thread itself scrolls.
struct TraceStrip: View {
    let trace: TurnState.Trace
    let rowID: String
    @State private var open = false
    @Environment(\.revealRow) private var reveal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                    Text(trace.summaryLine).lineLimit(2)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 6)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trace.summaryLine)
            .accessibilityHint(open ? String(localized: "收起执行过程") : String(localized: "展开执行过程"))
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "执行工具")).font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                    ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, s in
                        StepLine(step: s, current: false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.theirsFill.opacity(0.6)))
                .accessibilityElement(children: .combine)
            }
        }
        #if DEBUG
        .task { if Demo.screen == "chat-done-tap" { try? await Task.sleep(nanoseconds: 1_000_000_000); toggle() } }
        #endif
    }

    private func toggle() {
        open.toggle()
        if open { reveal?(rowID) }
    }
}

/// One tool step: ⌘ glyph (the Feishu channel's tool icon) or a spinner while it runs, then
/// 「<name> <summary>」.
struct StepLine: View {
    let step: TurnState.Step
    let current: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if current, !step.done {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "command").font(.caption2).foregroundStyle(Palette.tertiary)
            }
            // Live: one line, so the working card keeps its height. In the opened list the line
            // may wrap; it is already cut to `ToolLine.maxChars`.
            Text(step.line)
                .foregroundStyle(current ? Palette.text : Palette.secondary)
                .lineLimit(current ? 1 : nil)
                .truncationMode(.tail)
        }
        .font(current ? .footnote : .caption)
    }
}

/// 多多 working (design §4.4): sits where the answer will appear. While tools run the card stays
/// bounded, like the Feishu channel's collapsed panel: the phase, the current step, and the
/// earlier steps folded into 「+N 步」. Two rows at most, each one line.
struct WorkingBubble: View {
    let working: TurnState.Working
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if working.phase == .streaming {
                MarkdownView(working.text)
                Text(String(localized: "正在生成…")).font(.caption2).foregroundStyle(Palette.brand)
            } else {
                HStack(spacing: 6) {
                    ThinkingDots(animate: !reduceMotion)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brand)
                    if working.foldedSteps > 0 {
                        Spacer(minLength: 8)
                        Text(String(localized: "+\(working.foldedSteps) 步"))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.tertiary)
                    }
                }
                if let s = working.steps.last {
                    StepLine(step: s, current: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: working.steps.isEmpty || working.phase == .streaming ? nil : .infinity, alignment: .leading)
        .background(BubbleShape(mine: false, tail: true).fill(Palette.theirsFill))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if working.phase == .streaming { return String(localized: "多多正在回复：\(working.text)") }
        guard let s = working.steps.last else { return String(localized: "多多\(title)") }
        return String(localized: "多多\(title)，第 \(working.steps.count) 步：\(s.line)")
    }

    private var title: String {
        switch working.phase {
        case .received: String(localized: "收到了")
        case .thinking: String(localized: "在想")
        case .tool: String(localized: "在查")
        case .streaming: ""
        }
    }
}

struct ThinkingDots: View {
    var animate: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !animate)) { ctx in
            let step = animate ? Int(ctx.date.timeIntervalSinceReferenceDate * 4) % 3 : 2
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Palette.brand)
                        .frame(width: 6, height: 6)
                        .opacity(i <= step ? 1 : 0.35)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Links and phone numbers become tappable (design §4.3); no markdown (decision Q10).
private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
    | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

func linkified(_ s: String) -> AttributedString {
    var a = AttributedString(s)
    guard let det = linkDetector else { return a }
    let ns = s as NSString
    for m in det.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        guard let r = Range(m.range, in: s), let ar = Range(r, in: a) else { continue }
        if let url = m.url {
            a[ar].link = url
        } else if let phone = m.phoneNumber, let url = URL(string: "tel:" + phone.filter { "0123456789+".contains($0) }) {
            a[ar].link = url
        }
        a[ar].underlineStyle = .single
    }
    return a
}

/// Decorative bars for a voice note without a transcript yet.
struct VoiceGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let heights: [CGFloat] = [0.3, 0.6, 0.9, 0.5, 0.75, 1, 0.55, 0.35, 0.7, 0.9, 0.45, 0.6, 0.3, 0.8, 0.5, 0.35]
            let w = size.width / CGFloat(heights.count)
            for (i, h) in heights.enumerated() {
                let bh = max(2, h * size.height)
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * w + w * 0.3, y: (size.height - bh) / 2, width: w * 0.4, height: bh),
                              cornerRadius: w * 0.2), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The DuoDuo message a typed reply quotes, inside the user's own bubble: a bar and a few lines.
/// The full quote was sent; the bubble only shortens how much of it is drawn.
struct QuoteLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(Palette.mineText.opacity(0.5)).frame(width: 2)
            Text(text).font(.caption).lineLimit(3).opacity(0.8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(String(localized: "引用：\(text)"))
    }
}
