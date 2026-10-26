// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// The 多多 mark as 多多's live state. Motion says what it is doing (the coat dozes, cocks its
/// head to listen, its voice bars move to think and speak); a halo behind it says the same in
/// colour, readable from across a room. Listening follows the microphone and speaking aloud
/// follows the playback. Under Reduce Motion the mark is still and the halo keeps its colour. On
/// battery a resting mood (idle, unavailable) is one still frame with no frame timer; on external
/// power it moves as in every other mood.
struct LogoMark: View {
    /// The moods and their motion rule live in PocketCore, where they are tested.
    typealias Mood = MarkMood

    var mood: Mood
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off screen (ambient keeps the app running behind the lock screen) the frame timer pauses.
    @Environment(\.scenePhase) private var scene
    /// Off screen in the foldable's pane: built beside the shown level, not seen.
    @Environment(\.offstage) private var offstage
    @State private var level = Follower()

    /// The fastest motion (the voice bars, under 2 Hz) and the level (a block every 100 ms) read
    /// smoothly at 30 frames a second; the display's own rate (up to 120 on ProMotion) spends
    /// four times the work for nothing visible. Display only (docs/constants.md).
    static let frameInterval: TimeInterval = 1.0 / 30

    var body: some View {
        if reduceMotion || !mood.animates(on: BatteryPower.shared.source) {
            Drawing(mood: mood, t: 0, level: 0, dark: scheme == .dark)
        } else {
            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: scene != .active || offstage)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Drawing(mood: mood, t: t, level: level.step(to: source(), at: t), dark: scheme == .dark)
            }
        }
    }

    /// The signal the mood follows, sampled each frame.
    private func source() -> Float {
        switch mood {
        case .listening, .hearing: meterLevel()
        case .speaking(aloud: true): playbackLevel()
        default: 0
        }
    }

    /// Eases the level between the audio blocks (about 100 ms apart) so the halo does not step.
    /// A reference type: advancing it while drawing must not invalidate the view.
    private final class Follower {
        private var value: Float = 0
        private var last: Double = 0

        func step(to target: Float, at t: Double) -> Float {
            let dt = last == 0 ? 0 : min(t - last, 0.1)
            last = t
            // Time constant of the ease. Display only (docs/constants.md).
            value += (target - value) * Float(1 - exp(-dt / 0.08))
            return value
        }
    }

    private struct Drawing: View {
        var mood: Mood
        var t: Double
        var level: Float
        var dark: Bool

        var body: some View {
            Canvas { ctx, size in
                let g = LogoGeometry.self
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let lv = Double(level)
                if let (color, strength) = halo(lv) {
                    let r = side / 2
                    let shading = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [
                            // Strongest at the coat's edge (about 0.62 of the radius).
                            .init(color: color.opacity(0.95 * strength), location: 0.6),
                            .init(color: color.opacity(0.5 * strength), location: 0.78),
                            .init(color: color.opacity(0), location: 1),
                        ]),
                        center: center, startRadius: 0, endRadius: r * (0.9 + 0.1 * lv))
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: shading)
                }

                // The mark leaves the outer ring of the frame to the halo. Display only.
                let k = side / g.side * 0.7
                let off = mood == .unavailable
                let doze: Double = mood == .idle ? 1 : 0
                let still = off ? 0.0 : 1.0
                let breathe = 1 + still * (0.02 + 0.03 * doze) * sin(t * 2 * .pi / (3.4 + 1.6 * doze))
                let tilt: Double = switch mood {
                case .listening: -10 + 3 * sin(t * 1.3)
                case .hearing: -14 + 2 * sin(t * 2.1)
                case .idle: -6
                default: 0
                }
                // Logo units to points, then tilt and squash about the feet (512, 820).
                let m = CGAffineTransform(translationX: center.x - g.side * k / 2, y: center.y - g.side * k / 2)
                    .scaledBy(x: k, y: k)
                    .translatedBy(x: -g.origin.x, y: -g.origin.y)
                    .translatedBy(x: 512, y: 820)
                    .rotated(by: tilt * .pi / 180)
                    .scaledBy(x: breathe, y: 1 / breathe)
                    .translatedBy(x: -512, y: -820)
                var coat = Path()
                coat.addLines(g.outline.map { CGPoint(x: $0.0, y: $0.1) })
                coat.closeSubpath()
                coat = coat.applying(m)
                let ink = off ? (dark ? Color(hex: 0x8D8C86) : Color(hex: 0xABAAA5))
                    : (dark ? Color(hex: 0xFAF9F5) : Color(hex: 0x1C1C1A))
                let bars = off ? ink : (dark ? Color(hex: 0x1FD9DE) : Color(hex: 0x1C1C1A))
                let accent = off ? ink : (dark ? Color(hex: 0xF7A8C8) : Color(hex: 0xEE7FAE))
                // Filled so the halo shows around the coat, not through it.
                ctx.fill(coat, with: .color(dark ? Color(hex: 0x3A3835) : Color(hex: 0xFAF9F5)))
                ctx.stroke(coat, with: .color(ink), style: StrokeStyle(lineWidth: g.outlineWidth * k, lineJoin: .round))
                for (i, b) in g.bars.enumerated() {
                    let cy = (b.y1 + b.y2) / 2
                    let rest = (b.y2 - b.y1) / 2
                    let wave = 0.5 + 0.5 * sin(t * 11 + Double(i) * 1.7)
                    let talk: Double = switch mood {
                    // The bars keep their shape and move with the voice.
                    case .speaking(aloud: true): 70 * lv * (0.55 + 0.45 * wave)
                    case .speaking(aloud: false): 46 * wave
                    default: 0
                    }
                    let think = mood == .thinking ? 14 * (0.5 + 0.5 * sin(t * 4 + Double(i) * 0.9)) : 0
                    let half = (rest + talk + think) * (1 - 0.6 * doze)
                    var bar = Path()
                    bar.move(to: CGPoint(x: b.x, y: cy - half))
                    bar.addLine(to: CGPoint(x: b.x, y: cy + half))
                    ctx.stroke(bar.applying(m), with: .color(i == 4 ? accent : bars),
                               style: StrokeStyle(lineWidth: g.barWidth * k, lineCap: .round))
                }
            }
            .accessibilityHidden(true)
        }

        /// Colour and strength (0…1) of the halo; none while idle or unavailable.
        private func halo(_ lv: Double) -> (Color, Double)? {
            let teal = Color(hex: dark ? 0x1FD9DE : 0x2BB5B9)
            let violet = Color(hex: dark ? 0xA594FF : 0x8E7CF0)
            let pink = Color(hex: dark ? 0xF7A8C8 : 0xEE7FAE)
            return switch mood {
            case .idle, .unavailable: nil
            case .listening: (teal, (0.35 + 0.65 * lv))
            case .hearing: (teal, (0.7 + 0.3 * lv))
            case .thinking: (violet, (0.6 + 0.25 * sin(t * 2)))
            case .speaking(aloud: true): (pink, (0.45 + 0.55 * lv))
            case .speaking(aloud: false): (pink, (0.65 + 0.15 * sin(t * 3)))
            }
        }
    }
}

/// The phone's power source, live, for the mark. Battery monitoring is switched on once, when the
/// first mark reads this; iOS then posts a notification on each state change, with no polling.
@MainActor @Observable
final class BatteryPower {
    static let shared = BatteryPower()

    private(set) var source: PowerSource

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        source = Self.read()
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.read()
                if now != self.source { self.source = now }
            }
        }
    }

    private static func read() -> PowerSource {
        switch UIDevice.current.batteryState {
        case .charging, .full: .external
        // Unknown counts as battery: when iOS cannot say, the cheaper choice is the still mark.
        case .unplugged, .unknown: .battery
        @unknown default: .battery
        }
    }
}

private extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}
