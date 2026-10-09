// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import Markdown

/// DuoDuo's Markdown reduced to the blocks the app draws, with the display safety rules applied
/// here so the views never see an unsafe link or a remote image:
///
/// - Images are never loaded: an image becomes a link to its address (or plain text when the
///   address is not allowed), labelled with its alt text.
/// - Links keep only `http`, `https`, `mailto` and `tel` targets; any other target renders as its
///   text without a link.
/// - HTML is not interpreted: it renders as its literal source.
/// - Bare web addresses and phone numbers in text become links, as in plain messages.
public enum MarkdownDoc {
    public indirect enum Block: Equatable, Sendable {
        case heading(level: Int, AttributedString)
        case paragraph(AttributedString)
        /// `start` is the first number of an ordered list; nil for a bulleted list.
        case list(start: Int?, items: [Item])
        case quote([Block])
        case code(language: String?, text: String)
        case table(Table)
        case rule
    }

    public struct Item: Equatable, Sendable {
        /// nil for a plain item; true or false for a task-list checkbox.
        public var checked: Bool?
        public var blocks: [Block]
    }

    public struct Table: Equatable, Sendable {
        public enum Align: Equatable, Sendable { case leading, center, trailing }
        public var align: [Align]
        public var header: [AttributedString]
        public var rows: [[AttributedString]]
    }

    public static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    public static func parse(_ text: String) -> [Block] {
        let doc = Document(parsing: text)
        return doc.children.compactMap(block)
    }

    /// The text without Markdown syntax, one line per block (table rows joined with " · "), for
    /// places that show a message as plain lines, such as a quote preview.
    public static func plainText(_ text: String) -> String {
        func lines(_ b: Block) -> [String] {
            switch b {
            case let .heading(_, a), let .paragraph(a): return [String(a.characters)]
            case let .list(_, items): return items.flatMap { $0.blocks.flatMap(lines) }
            case let .quote(bs): return bs.flatMap(lines)
            case let .code(_, t): return [t]
            case let .table(t): return ([t.header] + t.rows).map { $0.map { String($0.characters) }.joined(separator: " · ") }
            case .rule: return []
            }
        }
        return parse(text).flatMap(lines).joined(separator: "\n")
    }

    /// The link target when its scheme is allowed, otherwise nil.
    public static func safeURL(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    // MARK: Blocks

    private static func block(_ m: Markup) -> Block? {
        switch m {
        case let h as Heading:
            return .heading(level: h.level, inlines(h))
        case let p as Paragraph:
            return .paragraph(inlines(p))
        case let l as UnorderedList:
            return .list(start: nil, items: l.listItems.map(item))
        case let l as OrderedList:
            return .list(start: Int(l.startIndex), items: l.listItems.map(item))
        case let q as BlockQuote:
            return .quote(q.children.compactMap(block))
        case let c as CodeBlock:
            return .code(language: c.language.flatMap { $0.isEmpty ? nil : $0 }, text: trimFinalNewline(c.code))
        case let h as HTMLBlock:
            return .paragraph(AttributedString(trimFinalNewline(h.rawHTML)))
        case let t as Markdown.Table:
            return .table(table(t))
        case is ThematicBreak:
            return .rule
        default:
            // Anything else (directives are not parsed) keeps its source text.
            let s = trimFinalNewline(m.format())
            return s.isEmpty ? nil : .paragraph(AttributedString(s))
        }
    }

    private static func item(_ li: ListItem) -> Item {
        let checked: Bool? = li.checkbox.map { $0 == .checked }
        return Item(checked: checked, blocks: li.children.compactMap(block))
    }

    private static func table(_ t: Markdown.Table) -> Table {
        let align: [Table.Align] = t.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            default: .leading
            }
        }
        let header: [AttributedString] = t.head.cells.map { inlines($0) }
        let rows: [[AttributedString]] = t.body.rows.map { row in row.cells.map { inlines($0) } }
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        func pad(_ cells: [AttributedString]) -> [AttributedString] {
            cells + Array(repeating: AttributedString(), count: max(0, width - cells.count))
        }
        let a = align + Array(repeating: Table.Align.leading, count: max(0, width - align.count))
        return Table(align: a, header: pad(header), rows: rows.map(pad))
    }

    private static func trimFinalNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    // MARK: Inlines

    private static func inlines(_ container: Markup) -> AttributedString {
        var out = AttributedString()
        for child in container.children {
            out += inline(child, intent: [])
        }
        return out
    }

    private static func inline(_ m: Markup, intent: InlinePresentationIntent) -> AttributedString {
        func styled(_ s: String, _ extra: InlinePresentationIntent = []) -> AttributedString {
            var a = AttributedString(s)
            let all = intent.union(extra)
            if !all.isEmpty { a.inlinePresentationIntent = all }
            return a
        }
        func children(_ extra: InlinePresentationIntent) -> AttributedString {
            var out = AttributedString()
            for c in m.children { out += inline(c, intent: intent.union(extra)) }
            return out
        }
        switch m {
        case let t as Markdown.Text:
            return linkified(styled(t.string))
        case is Emphasis:
            return children(.emphasized)
        case is Strong:
            return children(.stronglyEmphasized)
        case is Strikethrough:
            return children(.strikethrough)
        case let c as InlineCode:
            return styled(c.code, .code)
        case is SoftBreak, is LineBreak:
            // Chat text: a single newline is meant as a line break.
            return styled("\n")
        case let l as Markdown.Link:
            var a = children([])
            if let url = safeURL(l.destination) {
                a.link = url
            }
            if a.characters.isEmpty, let d = l.destination { a = styled(d) }
            return a
        case let img as Markdown.Image:
            var alt = AttributedString()
            for c in img.children { alt += inline(c, intent: intent) }
            let label = alt.characters.isEmpty ? (img.source ?? "") : String(alt.characters)
            var a = styled("🖼 " + label)
            if let url = safeURL(img.source) { a.link = url }
            return a
        case let h as InlineHTML:
            return styled(h.rawHTML)
        case let s as SymbolLink:
            return styled(s.destination ?? "", .code)
        default:
            return styled(m.format())
        }
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Bare addresses and phone numbers inside a text run become links (same detector as plain
    /// messages). Detected links are filtered by the same scheme rule.
    static func linkified(_ a: AttributedString) -> AttributedString {
        guard let detector else { return a }
        let s = String(a.characters)
        let ns = s as NSString
        var out = a
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            if let url = m.url, safeURL(url.absoluteString) != nil {
                out[lo..<hi].link = url
            } else if let phone = m.phoneNumber,
                      let url = URL(string: "tel:" + phone.filter { "0123456789+".contains($0) }) {
                out[lo..<hi].link = url
            }
        }
        return out
    }
}
