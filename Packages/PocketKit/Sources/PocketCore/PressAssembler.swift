// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Counters for one press, logged once per press.
public struct PressStats: Equatable, Codable, Sendable {
    public var pressID: UInt16
    public var packets = 0
    public var bytes = 0
    /// PRESS_END's packet count; nil when the press ended without one.
    public var declaredCount: Int?
    /// Sequence numbers skipped (packets lost on the link).
    public var gaps = 0
    /// Packets dropped because their sequence number was already seen.
    public var duplicates = 0
    /// The first message was AUDIO, not PRESS_START (for example after a relaunch mid-press).
    public var implicitStart = false
    public var end: End = .pressEnd

    public enum End: String, Codable, Sendable { case pressEnd, linkLost, superseded }

    public init(pressID: UInt16) { self.pressID = pressID }
}

public struct CompletedPress: Equatable, Sendable {
    public var pressID: UInt16
    public var packets: [Data]
    public var stats: PressStats
}

/// Turns PRESS_START / AUDIO / PRESS_END into one completed press (docs/ble-protocol.md §8: one
/// voice note per press). Per-packet work is one append and two integer comparisons: it runs for
/// every BLE notification while the app is in the background, and iOS kills a background app
/// above 80 % CPU over 60 s.
public struct PressAssembler {
    public enum Event: Equatable {
        case started(pressID: UInt16, implicit: Bool)
        case completed(CompletedPress)
    }

    private struct Building {
        var packets: [Data] = []
        var lastSeq: UInt16?
        var stats: PressStats
    }

    private var current: Building?
    private var lastCompleted: UInt16?

    public init() {}

    public var activePressID: UInt16? { current?.stats.pressID }

    public mutating func handle(_ message: DeviceMessage) -> [Event] {
        switch message {
        case .pressStart(let id):
            var events = finish(.superseded)
            current = Building(stats: PressStats(pressID: id))
            events.append(.started(pressID: id, implicit: false))
            return events
        case .audio(let id, let seq, let packet):
            var events: [Event] = []
            if current?.stats.pressID != id {
                events = finish(.superseded)
                var stats = PressStats(pressID: id)
                stats.implicitStart = true
                current = Building(stats: stats)
                events.append(.started(pressID: id, implicit: true))
            }
            append(seq: seq, packet: packet)
            return events
        case .pressEnd(let id, let count):
            guard current?.stats.pressID == id else {
                // A repeated PRESS_END, or one whose press never started: nothing to deliver.
                if lastCompleted == id { return [] }
                var stats = PressStats(pressID: id)
                stats.declaredCount = Int(count)
                lastCompleted = id
                return [.completed(CompletedPress(pressID: id, packets: [], stats: stats))]
            }
            current?.stats.declaredCount = Int(count)
            return finish(.pressEnd)
        case .info, .status, .keepalive:
            return []
        }
    }

    /// The link dropped: deliver what was captured so the speech is not lost silently.
    public mutating func linkLost() -> [Event] { finish(.linkLost) }

    private mutating func append(seq: UInt16, packet: Data) {
        guard var b = current else { return }
        current = nil // keep the array uniquely referenced so append does not copy
        if let last = b.lastSeq {
            let step = seq &- last
            // Serial-number arithmetic: a step past half the u16 space is a step backwards.
            if step == 0 || step > 0x8000 {
                b.stats.duplicates += 1
                current = b
                return
            }
            b.stats.gaps += Int(step) - 1
        } else {
            // The first packet of a press carries seq 0 unless earlier ones were lost.
            b.stats.gaps += b.stats.implicitStart ? 0 : Int(seq)
        }
        b.lastSeq = seq
        b.packets.append(packet)
        b.stats.packets += 1
        b.stats.bytes += packet.count
        current = b
    }

    private mutating func finish(_ end: PressStats.End) -> [Event] {
        guard var b = current else { return [] }
        current = nil
        b.stats.end = end
        lastCompleted = b.stats.pressID
        return [.completed(CompletedPress(pressID: b.stats.pressID, packets: b.packets, stats: b.stats))]
    }
}
