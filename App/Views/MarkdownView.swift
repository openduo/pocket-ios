// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// DuoDuo's Markdown answer. Safety rules (no remote images, allowed link schemes, literal HTML)
/// are applied by `MarkdownDoc`; this view only draws. Nothing is folded or cut: code blocks and
/// tables scroll sideways and can be copied.
struct MarkdownView: View {
    let blocks: [MarkdownDoc.Block]
    var color: Color = Palette.theirsText

    init(_ text: String, color: Color = Palette.theirsText) {
        blocks = MarkdownDoc.parse(text)
        self.color = color
    }

    init(blocks: [MarkdownDoc.Block], color: Color) {
        self.blocks = blocks
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                BlockView(block: b, color: color)
            }
        }
        .foregroundStyle(color)
        .tint(Palette.brand)
    }
}

private struct BlockView: View {
    let block: MarkdownDoc.Block
    let color: Color

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(text).font(.body).textSelection(.enabled)
        case let .list(start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker(start: start, index: i, checked: item.checked))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Palette.secondary)
                        MarkdownView(blocks: item.blocks, color: color)
                    }
                }
            }
        case let .quote(blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.brand.opacity(0.6)).frame(width: 3)
                MarkdownView(blocks: blocks, color: Palette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(language, text):
            CodeBlockView(language: language, text: text)
        case let .table(t):
            TableView(table: t)
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
    }

    private func marker(start: Int?, index: Int, checked: Bool?) -> String {
        if let checked { return checked ? "☑" : "☐" }
        if let start { return "\(start + index)." }
        return "•"
    }
}

/// A copy button above sideways-scrolling monospaced text; long lines are not wrapped.
private struct CodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language { Text(language).font(.caption2).foregroundStyle(Palette.tertiary) }
                Spacer()
                CopyButton(text: text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.top, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.chip))
    }
}

/// Columns keep their natural width; a wide table scrolls sideways.
private struct TableView: View {
    let table: MarkdownDoc.Table

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            CopyButton(text: plain)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { i, c in
                            cell(c, i).font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { i, c in
                                cell(c, i).font(.subheadline)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.hairline))
        }
    }

    private func cell(_ text: AttributedString, _ column: Int) -> some View {
        let align: MarkdownDoc.Table.Align = column < table.align.count ? table.align[column] : .leading
        return Text(text)
            .textSelection(.enabled)
            .fixedSize()
            .gridColumnAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
    }

    /// Tab-separated, so a paste into a spreadsheet keeps the columns.
    private var plain: String {
        ([table.header] + table.rows)
            .map { $0.map { String($0.characters) }.joined(separator: "\t") }
            .joined(separator: "\n")
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? String(localized: "已拷贝") : String(localized: "拷贝"),
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.secondary)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
