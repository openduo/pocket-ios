// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import XCTest
@testable import PocketCore

final class DuoLayoutTests: XCTestCase {
    private func choose(_ rw: Bool, _ ch: Bool, _ w: Double, _ h: Double, _ fold: DuoLayout.Fold? = nil) -> DuoLayout {
        DuoLayout.choose(regularWidth: rw, compactHeight: ch, width: w, height: h, fold: fold)
    }

    func testAPhoneIsThePhoneLayout() {
        XCTAssertEqual(choose(false, false, 393, 852), .phone)
        XCTAssertFalse(DuoLayout.phone.roomInline)
    }

    func testTheOuterDisplayInLandscapeIsTheTent() {
        XCTAssertEqual(choose(false, true, 678, 466), .tent)
    }

    func testLandscapeIsSideByOpenFlatOrAsABook() {
        XCTAssertEqual(choose(true, false, 951, 669), .side)
        let fold = DuoLayout.Fold(x: 470, y: 0, width: 12, height: 669)
        XCTAssertEqual(choose(true, false, 951, 669, fold), .side)
    }

    func testOpenFlatPortraitStacksAtTheMiddle() {
        XCTAssertEqual(choose(true, false, 669, 951), .stacked(top: 475.5, gap: 0))
    }

    func testAHorizontalFoldIsTabletopWhateverTheSizeClasses() {
        let fold = DuoLayout.Fold(x: 0, y: 470, width: 669, height: 12)
        XCTAssertEqual(choose(true, false, 669, 951, fold), .tabletop(top: 470, gap: 12))
        XCTAssertTrue(DuoLayout.tabletop(top: 470, gap: 12).roomInline)
    }

    // MARK: last exchange

    private func mine(_ t: String) -> ThreadRow {
        .mine(.init(id: "m" + t, text: t, at: nil, voiceSource: nil, durationMs: nil, attachments: [], delivery: nil))
    }

    private func duoduo(_ t: String) -> ThreadRow {
        .duoduo(.init(id: "d" + t, text: t, at: nil, spoken: nil, showTime: true, trace: .empty))
    }

    private func heard(_ t: String) -> ThreadRow {
        .heard(.init(id: "h" + t, lines: [.init(speaker: "V1", text: t)], folded: []))
    }

    func testTheLastAnswerAndMyQuestionBeforeIt() {
        let x = LastExchange.from([mine("a"), duoduo("A"), mine("b"), duoduo("B")])
        XCTAssertEqual(x, LastExchange(question: "b", mine: true, answer: "B"))
    }

    func testARoomLineIsTheQuestionWhenISaidNothing() {
        let x = LastExchange.from([heard("几点开会"), duoduo("十点")])
        XCTAssertEqual(x, LastExchange(question: "几点开会", mine: false, answer: "十点"))
    }

    func testAQuestionAfterTheLastAnswerIsNotItsQuestion() {
        let x = LastExchange.from([mine("a"), duoduo("A"), mine("still waiting")])
        XCTAssertEqual(x, LastExchange(question: "a", mine: true, answer: "A"))
    }

    func testALiveAnswerCounts() {
        let live = TurnState.Provisional(text: "正在答", messageIDs: ["x"], trace: .empty, at: Date())
        let x = LastExchange.from([mine("q"), .provisional(live, id: "ans:x")])
        XCTAssertEqual(x?.answer, "正在答")
    }

    func testNoAnswerNoExchange() {
        XCTAssertNil(LastExchange.from([mine("q")]))
        XCTAssertNil(LastExchange.from([]))
    }
}
