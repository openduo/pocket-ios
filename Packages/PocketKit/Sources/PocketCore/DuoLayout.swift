// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation

/// Which screen layout the app shows, chosen from the size classes, the window size and the fold
/// the system reserves, never from the device model (docs/design/iphone-duo.md).
///
/// One order holds in every layout: the room, then 多多, then an opened session. Opening a session
/// pushes 多多 away from it: to the right in `side`, up in `stacked` and `tabletop`.
public enum DuoLayout: Equatable, Sendable {
    /// Closed, portrait, and every other iPhone: today's single column.
    case phone
    /// The outer display in landscape: standing on a table, or the closed phone held sideways.
    case tent
    /// Inner display, landscape. The system arranges the two sides around the fold.
    case side
    /// Inner display, portrait, open flat. `top` is the top half's height, `gap` the fold's.
    case stacked(top: Double, gap: Double)
    /// Half-folded on a surface: the top half stands upright, out of reach.
    case tabletop(top: Double, gap: Double)

    /// A fold the system reserves, in the window's coordinates.
    public struct Fold: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public static func choose(regularWidth: Bool, compactHeight: Bool, width: Double, height: Double,
                              fold: Fold?) -> DuoLayout {
        if let fold, fold.width > fold.height { return .tabletop(top: fold.y, gap: fold.height) }
        if regularWidth, width > height { return .side }
        if regularWidth { return .stacked(top: fold?.y ?? height / 2, gap: fold?.height ?? 0) }
        if compactHeight { return .tent }
        return .phone
    }

    /// The room is drawn in the layout, so ambient mode needs no full-screen call view and no pill.
    public var roomInline: Bool {
        switch self {
        case .phone: false
        case .tent, .side, .stacked, .tabletop: true
        }
    }
}

/// The last answer and what it answered, for the room display read from a distance.
public struct LastExchange: Equatable, Sendable {
    /// What I said, or failing that the last line heard in the room, before the answer.
    public var question: String?
    public var mine: Bool
    public var answer: String

    /// The newest 多多 answer with text (a live one included) and the nearest question before it.
    public static func from(_ rows: [ThreadRow]) -> LastExchange? {
        guard let i = rows.lastIndex(where: { answerText($0) != nil }), let answer = answerText(rows[i]) else { return nil }
        for r in rows[..<i].reversed() {
            switch r {
            case .mine(let m) where !m.text.isEmpty:
                return LastExchange(question: m.text, mine: true, answer: answer)
            case .heard(let h):
                if let line = h.lines.last { return LastExchange(question: line.text, mine: false, answer: answer) }
            default:
                continue
            }
        }
        return LastExchange(question: nil, mine: false, answer: answer)
    }

    private static func answerText(_ r: ThreadRow) -> String? {
        switch r {
        case .duoduo(let d): d.text.isEmpty ? nil : d.text
        case .provisional(let p, _): p.text.isEmpty ? nil : p.text
        default: nil
        }
    }
}
