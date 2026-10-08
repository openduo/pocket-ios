// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class ToolLineTests: XCTestCase {
    func testDescriptionLeadsOverCommand() {
        let input = #"{"command":"df -h / /System/Volumes/Data 2>/dev/null | awk '{print $1}'","description":"Show disk space"}"#
        XCTAssertEqual(ToolLine.summarize(input), "Show disk space")
    }

    func testCommandAloneIsFlattenedAndCut() {
        let input = #"{"command":"git log --oneline --decorate 2>&1 | head -40; echo =====;\ngit status"}"#
        let s = ToolLine.summarize(input)!
        XCTAssertEqual(s.count, ToolLine.maxChars)
        XCTAssertTrue(s.hasPrefix("git log --oneline --decorate 2>&1"))
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertFalse(s.contains("\n"))
    }

    func testFilePathPathPatternQueryURL() {
        XCTAssertEqual(ToolLine.summarize(#"{"file_path":"/Users/x/notes.md","limit":20}"#), "/Users/x/notes.md")
        XCTAssertEqual(ToolLine.summarize(#"{"path":"src","pattern":"TODO"}"#), "src")
        XCTAssertEqual(ToolLine.summarize(#"{"pattern":"**/*.swift"}"#), "**/*.swift")
        XCTAssertEqual(ToolLine.summarize(#"{"query":"北京 明天 天气"}"#), "北京 明天 天气")
        XCTAssertEqual(ToolLine.summarize(#"{"url":"https://example.com/a"}"#), "https://example.com/a")
        XCTAssertEqual(ToolLine.summarize(#"{"files":["a.txt","b.txt"]}"#), "a.txt")
    }

    func testUnknownJSONTakesFirstStringInKeyOrder() {
        // Notify-style input: no known key, the first string value in the daemon's order.
        let input = #"{"notify_content":"Alice's request\nrelayed from the phone session","zeta":"z","count":2}"#
        XCTAssertEqual(ToolLine.summarize(input), ToolLine.cut("Alice's request relayed from the phone session"))
        XCTAssertEqual(ToolLine.summarize(#"{"b":"second","a":"first"}"#), "second")
        XCTAssertEqual(ToolLine.summarize(#"{"n":{"x":"nested"},"v":"top"}"#), "top")
        XCTAssertNil(ToolLine.summarize(#"{"n":1,"ok":true}"#))
        XCTAssertNil(ToolLine.summarize("{}"))
        XCTAssertNil(ToolLine.summarize(#"[1,2]"#))
    }

    func testNotJSONAndEmpty() {
        XCTAssertEqual(ToolLine.summarize("收到语音，已转写"), "收到语音，已转写")
        XCTAssertEqual(ToolLine.summarize(#""a string""#), "a string")
        XCTAssertNil(ToolLine.summarize(nil))
        XCTAssertNil(ToolLine.summarize("  "))
        XCTAssertNil(ToolLine.summarize(#"{"description":"  ","x":1}"#))
    }

    func testLongCJKCountsCharacters() {
        let long = String(repeating: "查", count: 100)
        let s = ToolLine.summarize(#"{"prompt":""# + long + #""}"#)!
        XCTAssertEqual(s.count, ToolLine.maxChars)
        XCTAssertEqual(s, String(repeating: "查", count: ToolLine.maxChars - 1) + "…")
        XCTAssertEqual(ToolLine.cut(String(repeating: "字", count: ToolLine.maxChars)).count, ToolLine.maxChars)
        // A very long input (a Write of a big file) still ends in one row.
        let big = #"{"file_path":"/tmp/out.txt","content":""# + String(repeating: "x", count: 200_000) + #""}"#
        XCTAssertEqual(ToolLine.summarize(big), "/tmp/out.txt")
    }

    func testMCPDisplayName() {
        XCTAssertEqual(ToolLine.displayName("mcp__duoduo__Notify"), "Notify")
        XCTAssertEqual(ToolLine.displayName("mcp__claude_ai_Gmail__search_threads"), "search_threads")
        XCTAssertEqual(ToolLine.displayName("Bash"), "Bash")
        XCTAssertEqual(ToolLine.displayName("mcp__x"), "mcp__x")
    }

    func testEscapedKeysKeepOrder() {
        XCTAssertEqual(ToolLine.topLevelKeys(#"{"a\"b":"1","c":{"d":"2"},"e":["f","g"],"h":"3"}"#), ["a\"b", "c", "e", "h"])
    }
}

final class TurnStepTests: XCTestCase {
    private func tool(_ label: String, _ input: String? = nil) -> [String: Any] {
        var f: [String: Any] = ["type": "turn", "utt_id": NSNull(), "phase": "tool", "label": label]
        if let input { f["input_summary"] = input }
        return f
    }

    func testChannelFramesMakeOneStepPerCall() {
        var t = TurnState()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.expect(uttID: "u1", now: t0)
        // The channel's frame sequence: bash, its raw input, bash ✓, Notify, its input, Notify ✓.
        t.handle(frame: tool("bash"))
        t.handle(frame: tool("bash", #"{"command":"git log --oneline --decorate 2>&1 | head -40"}"#))
        t.handle(frame: tool("bash ✓"))
        t.handle(frame: tool("mcp__duoduo__Notify"))
        t.handle(frame: tool("mcp__duoduo__Notify", #"{"notify_content":"relayed"}"#))
        XCTAssertEqual(t.working?.steps.map(\.line), ["bash git log --oneline --decorate 2>&1…", "Notify relayed"])
        XCTAssertEqual(t.working?.steps.map(\.done), [true, false])
        t.handle(frame: tool("Notify ✓"))
        XCTAssertEqual(t.working?.steps.map(\.done), [true, true])
        XCTAssertFalse(t.working!.steps.map(\.line).joined().contains("{"))
        t.handle(frame: ["type": "answer_final", "utt_id": "u1", "text": "好了"], now: t0.addingTimeInterval(12))
        XCTAssertEqual(t.provisional.first?.trace.elapsed, 12)
        XCTAssertEqual(t.provisional.first?.trace.steps.count, 2)
        XCTAssertEqual(t.provisional.first?.trace.summaryLine, "任务已完成 · 2 步 · 12 秒")
    }

    func testSummaryLineDurations() {
        XCTAssertEqual(TurnState.Trace.duration(0.2), "1 秒")
        XCTAssertEqual(TurnState.Trace.duration(59.4), "59 秒")
        XCTAssertEqual(TurnState.Trace.duration(120), "2 分")
        XCTAssertEqual(TurnState.Trace.duration(168), "2 分 48 秒")
        XCTAssertEqual(TurnState.Trace(steps: [.init(name: "Bash")]).summaryLine, "任务已完成 · 1 步")
    }

    func testParallelCallsPairInOrderAndResultWithoutCall() {
        var t = TurnState()
        t.expect(uttID: "u1")
        t.handle(frame: tool("Read", #"{"file_path":"a.md"}"#))
        t.handle(frame: tool("Read", #"{"file_path":"b.md"}"#))
        t.handle(frame: ["type": "turn", "phase": "thinking"])
        t.handle(frame: tool("Read ✓"))
        XCTAssertEqual(t.working?.steps.map(\.done), [true, false])
        t.handle(frame: tool("Read ✓"))
        // A runtime that only reports results still gets a line.
        t.handle(frame: tool("WebSearch ✓"))
        XCTAssertEqual(t.working?.steps.map(\.line), ["Read a.md", "Read b.md", "WebSearch"])
        XCTAssertEqual(t.working?.steps.map(\.done), [true, true, true])
    }

    func testRepeatedEarlyFrameIsNotAStep() {
        var t = TurnState()
        t.expect(uttID: "u1")
        XCTAssertTrue(t.handle(frame: tool("Bash")))
        XCTAssertFalse(t.handle(frame: tool("Bash")))
        XCTAssertEqual(t.working?.steps.count, 1)
        XCTAssertEqual(t.working?.toolLabel, "Bash")
    }

    /// The ambient view shows `toolLabel`; it must be the working card's current step line.
    func testAmbientLabelIsTheCardsCurrentStepLine() {
        var t = TurnState()
        t.expect(uttID: "u1")
        t.handle(frame: tool("Bash"))
        t.handle(frame: tool("Bash", #"{"command":"df -h /","description":"查看磁盘剩余空间，包括系统卷和数据卷的可用容量与快照占用"}"#))
        let line = t.working?.steps.last?.line
        XCTAssertEqual(t.working?.toolLabel, line)
        XCTAssertEqual(line, "Bash " + ToolLine.cut("查看磁盘剩余空间，包括系统卷和数据卷的可用容量与快照占用"))
        XCTAssertFalse(line?.contains("{") ?? true)
        t.handle(frame: ["type": "turn", "phase": "thinking"])
        XCTAssertNil(t.working?.toolLabel)
    }
}
