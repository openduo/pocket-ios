// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
@testable import PocketCore
import XCTest

final class MarkdownDocTests: XCTestCase {
    private func text(_ a: AttributedString) -> String { String(a.characters) }

    private func links(_ a: AttributedString) -> [URL] {
        a.runs.compactMap(\.link)
    }

    func testBlocks() {
        let md = """
        ## Title

        Para with **bold** and `code`.

        1. one
        2. two

        - [x] done
        - [ ] todo

        > quoted

        ```swift
        let x = 1
        ```

        ---
        """
        let blocks = MarkdownDoc.parse(md)
        XCTAssertEqual(blocks.count, 7)
        guard case let .heading(level, h) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(text(h), "Title")
        guard case let .paragraph(p) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(text(p), "Para with bold and code.")
        XCTAssertTrue(p.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
        XCTAssertTrue(p.runs.contains { $0.inlinePresentationIntent == .code })
        guard case let .list(start, items) = blocks[2] else { return XCTFail() }
        XCTAssertEqual(start, 1)
        XCTAssertEqual(items.count, 2)
        guard case let .list(nil, tasks) = blocks[3] else { return XCTFail() }
        XCTAssertEqual(tasks.map(\.checked), [true, false])
        guard case .quote = blocks[4] else { return XCTFail() }
        XCTAssertEqual(blocks[5], .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(blocks[6], .rule)
    }

    func testTablePadsShortRows() {
        let md = """
        | a | b | c |
        |:-|:-:|-:|
        | 1 | 2 |
        """
        guard case let .table(t) = MarkdownDoc.parse(md).first else { return XCTFail() }
        XCTAssertEqual(t.align, [.leading, .center, .trailing])
        XCTAssertEqual(t.header.map(text), ["a", "b", "c"])
        XCTAssertEqual(t.rows.count, 1)
        XCTAssertEqual(t.rows[0].count, 3)
    }

    func testLinkSchemes() {
        guard case let .paragraph(p) = MarkdownDoc.parse("[ok](https://a.example) [bad](javascript:alert(1)) [app](someapp://x)").first
        else { return XCTFail() }
        XCTAssertEqual(links(p), [URL(string: "https://a.example")!])
        XCTAssertEqual(text(p), "ok bad app")
    }

    func testImagesAreNotLoaded() {
        guard case let .paragraph(p) = MarkdownDoc.parse("![cat](https://img.example/c.png) ![x](file:///etc/passwd)").first
        else { return XCTFail() }
        XCTAssertEqual(text(p), "🖼 cat 🖼 x")
        XCTAssertEqual(links(p), [URL(string: "https://img.example/c.png")!])
    }

    func testHTMLIsLiteral() {
        let blocks = MarkdownDoc.parse("<script>alert(1)</script>\n\nhi <b>x</b>")
        XCTAssertEqual(blocks.first, .paragraph(AttributedString("<script>alert(1)</script>")))
        guard case let .paragraph(p) = blocks.last else { return XCTFail() }
        XCTAssertEqual(text(p), "hi <b>x</b>")
    }

    func testSoftBreakIsLineBreak() {
        guard case let .paragraph(p) = MarkdownDoc.parse("line one\nline two").first else { return XCTFail() }
        XCTAssertEqual(text(p), "line one\nline two")
    }

    func testBareURLBecomesLink() {
        guard case let .paragraph(p) = MarkdownDoc.parse("see https://openduo.ai now").first else { return XCTFail() }
        XCTAssertEqual(links(p).map(\.host), ["openduo.ai"])
    }

    func testPlainTextIsOneParagraph() {
        XCTAssertEqual(MarkdownDoc.parse("hello"), [.paragraph(AttributedString("hello"))])
    }

    func testPlainText() {
        let md = "## Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- **x**"
        XCTAssertEqual(MarkdownDoc.plainText(md), "Title\na · b\n1 · 2\nx")
    }
}
