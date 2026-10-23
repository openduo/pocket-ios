// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

@testable import PocketCore
import XCTest

final class ArrivalPlaceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let beijing = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-10-20T14:02:00+08:00.
    private let t0 = Date(timeIntervalSince1970: 1_792_476_120)

    override func setUp() {
        suite = "ArrivalPlaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func place(_ name: String, _ area: String, _ minutes: Double = 0) -> ArrivalPlace {
        ArrivalPlace(name: name, area: area, arrived: t0.addingTimeInterval(minutes * 60))
    }

    private func decode(_ header: String) -> [String: Any]? {
        guard let s = header.removingPercentEncoding else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    // MARK: header

    func testHeaderIsPercentEncodedJSONWithoutPrevious() throws {
        let r = PlaceReport(place: place("望京 SOHO", "北京市朝阳区"), previous: nil, timeZone: beijing)
        let v = r.headerValue
        XCTAssertTrue(v.allSatisfy { $0.isASCII }, v)
        XCTAssertFalse(v.contains(" "))
        XCTAssertFalse(v.contains("\""))
        XCTAssertTrue(v.hasPrefix("%7B"))
        XCTAssertTrue(v.contains("%E6%9C%9B")) // 望
        let o = try XCTUnwrap(decode(v))
        XCTAssertEqual(o["name"] as? String, "望京 SOHO")
        XCTAssertEqual(o["area"] as? String, "北京市朝阳区")
        XCTAssertEqual(o["arrived"] as? String, "2026-10-20T14:02:00+08:00")
        XCTAssertNil(o["previous"])
        XCTAssertEqual(Set(o.keys), ["name", "area", "arrived"])
        XCTAssertEqual(r.headers, ["X-Ambient-Place": v])
    }

    func testHeaderCarriesPrevious() throws {
        let r = PlaceReport(place: place("望京 SOHO", "北京市朝阳区"), previous: (name: "回龙观", area: "北京市昌平区"),
                            timeZone: beijing)
        let o = try XCTUnwrap(decode(r.headerValue))
        let prev = try XCTUnwrap(o["previous"] as? [String: Any])
        XCTAssertEqual(prev["name"] as? String, "回龙观")
        XCTAssertEqual(prev["area"] as? String, "北京市昌平区")
        XCTAssertEqual(Set(prev.keys), ["name", "area"])
    }

    func testTimestampAlwaysHasAnOffset() {
        XCTAssertEqual(PlaceReport.timestamp(t0, TimeZone(identifier: "UTC")!), "2026-10-20T06:02:00+00:00")
        XCTAssertEqual(PlaceReport.timestamp(t0, TimeZone(identifier: "America/Los_Angeles")!), "2026-10-19T23:02:00-07:00")
    }

    func testMessageHeadersCarryThePlaceOnlyWhenGiven() {
        let s = Surface(display: .phone, spoken: false)
        let r = PlaceReport(place: place("A", "B"), previous: nil, timeZone: beijing)
        XCTAssertNil(ChannelPaths.typedMessageHeaders(key: "k", surface: s)["X-Ambient-Place"])
        XCTAssertEqual(ChannelPaths.typedMessageHeaders(key: "k", surface: s, place: r)["X-Ambient-Place"], r.headerValue)
        let note = VoiceNote(source: .phone, packets: [])
        XCTAssertNil(VoiceUploader.headers(for: note, surface: s)["X-Ambient-Place"])
        XCTAssertEqual(VoiceUploader.headers(for: note, surface: s, place: r)["X-Ambient-Place"], r.headerValue)
        XCTAssertEqual(VoiceUploader.headers(for: note, surface: s, place: r)["X-Ambient-Display"], "phone")
    }

    func testVoiceUploadSendsThePlaceOnEveryAttempt() async {
        let note = VoiceNote(source: .passport, packets: [Data([1])])
        let key = note.id.uuidString.lowercased()
        let t = FakeTransport([.status(500, "{}"), .status(202, #"{"message_id":"\#(key)"}"#)])
        let r = PlaceReport(place: place("A", "B"), previous: nil, timeZone: beijing)
        let up = VoiceUploader(transport: t, tuning: PocketTuning(), sleep: { _ in }, now: { 0 })
        let out = await up.upload(note, room: "r", surface: Surface(display: .later, spoken: false), place: r)
        XCTAssertEqual(out.outcome, .accepted(messageID: key))
        XCTAssertEqual(t.seen.map { $0.headers["X-Ambient-Place"] }, [r.headerValue, r.headerValue])
    }

    func testArea() {
        XCTAssertEqual(ArrivalPlace.area(city: "北京市", district: "朝阳区"), "北京市朝阳区")
        XCTAssertEqual(ArrivalPlace.area(city: "北京市", district: "北京市"), "北京市")
        XCTAssertEqual(ArrivalPlace.area(city: "San Francisco", district: "Mission"), "Mission, San Francisco")
        XCTAssertEqual(ArrivalPlace.area(city: nil, district: "Mission"), "Mission")
        XCTAssertEqual(ArrivalPlace.area(city: nil, district: " "), "")
    }

    // MARK: ledger

    func testNothingPendingWithoutAnArrival() {
        XCTAssertNil(PlaceLedger(defaults: defaults).pending())
    }

    func testFirstArrivalIsPendingWithoutPrevious() {
        let l = PlaceLedger(defaults: defaults)
        XCTAssertTrue(l.arrived(place("A", "X")))
        let r = l.pending(timeZone: beijing)
        XCTAssertEqual(r?.place, place("A", "X"))
        XCTAssertNil(r?.previous)
    }

    func testSamePlaceKeepsTheOriginalArrival() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X", 0))
        XCTAssertFalse(l.arrived(place("A", "X", 30)))
        XCTAssertEqual(l.current?.arrived, t0)
        // A different area with the same name is a different place.
        XCTAssertTrue(l.arrived(place("A", "Y", 60)))
        XCTAssertEqual(l.current, place("A", "Y", 60))
    }

    func testAcceptedClearsPendingAndNextChangeNamesPrevious() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X"))
        let r = l.pending()
        l.settle(r, accepted: true)
        XCTAssertNil(l.pending())
        // The same place again changes nothing.
        l.arrived(place("A", "X", 10))
        XCTAssertNil(l.pending())
        l.arrived(place("B", "Y", 20))
        let next = l.pending()
        XCTAssertEqual(next?.place.name, "B")
        XCTAssertEqual(next?.previous?.name, "A")
        XCTAssertEqual(next?.previous?.area, "X")
    }

    func testFailureLeavesItPending() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X"))
        let r = l.pending()
        l.settle(r, accepted: false)
        XCTAssertEqual(l.pending(), r)
        XCTAssertNil(l.reported)
        l.settle(nil, accepted: true)
        XCTAssertNil(l.reported)
    }

    func testAcceptedMarksThePlaceThatWasSentNotTheCurrentOne() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X", 0))
        let sent = l.pending()
        l.arrived(place("B", "Y", 10))
        l.settle(sent, accepted: true)
        XCTAssertEqual(l.reported, place("A", "X", 0))
        let r = l.pending()
        XCTAssertEqual(r?.place.name, "B")
        XCTAssertEqual(r?.previous?.name, "A")
    }

    func testAnOlderPlaceAcceptedLateDoesNotReplaceANewerOne() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X", 0))
        let older = l.pending()
        l.arrived(place("B", "Y", 10))
        l.settle(l.pending(), accepted: true)
        l.settle(older, accepted: true)
        XCTAssertEqual(l.reported?.name, "B")
        XCTAssertNil(l.pending())
    }

    func testReturningToTheReportedPlaceOmitsPrevious() {
        let l = PlaceLedger(defaults: defaults)
        l.arrived(place("A", "X", 0))
        l.settle(l.pending(), accepted: true)
        l.arrived(place("B", "Y", 10)) // never reported
        l.arrived(place("A", "X", 20))
        let r = l.pending()
        XCTAssertEqual(r?.place, place("A", "X", 20))
        XCTAssertNil(r?.previous)
    }

    func testStateSurvivesANewLedgerAndClearForgetsIt() {
        PlaceLedger(defaults: defaults).arrived(place("A", "X"))
        let l = PlaceLedger(defaults: defaults)
        XCTAssertEqual(l.current, place("A", "X"))
        l.settle(l.pending(), accepted: true)
        XCTAssertEqual(PlaceLedger(defaults: defaults).reported, place("A", "X"))
        l.clear()
        XCTAssertNil(l.current)
        XCTAssertNil(l.reported)
        XCTAssertNil(l.pending())
    }
}
