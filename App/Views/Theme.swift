// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import SwiftUI
import UIKit

/// duoduo colours (design §2, from the ambient web tokens): warm paper in light, warm black in
/// dark, one teal accent.
enum Palette {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let background = dyn(0xF5F4ED, 0x0E0E0D)
    static let grouped = dyn(0xEFEEE6, 0x0B0B0A)
    static let cell = dyn(0xFAF9F5, 0x171716)
    static let brand = dyn(0x1A7175, 0x1FD9DE)
    static let onBrand = dyn(0xFAF9F5, 0x0A1414)
    static let mineFill = dyn(0x1A7175, 0x12484B)
    static let mineText = dyn(0xFAF9F5, 0xEFFCFC)
    static let theirsFill = dyn(0xE9E8DF, 0x1F1F1D)
    static let theirsText = dyn(0x141413, 0xDDDCD5)
    static let text = dyn(0x141413, 0xF5F4ED)
    static let secondary = dyn(0x60605D, 0xB4B3AC)
    static let tertiary = dyn(0x80807C, 0x8D8C86)
    static let placeholder = dyn(0xABAAA5, 0x5C5B57)
    static let hairline = dyn(0xDAD9D3, 0x282826)
    static let ok = dyn(0x0E9F6E, 0x4AC994)
    static let attention = dyn(0x7A3E00, 0xD9A066)
    static let attentionFill = dyn(0xECE2CC, 0x2A2015)
    /// Soft brand wash for rings and the pill.
    static let brandWash = dyn(0xD5E5E3, 0x0F3537)
    static let chip = dyn(0xE6E5DC, 0x232321)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 多多's live state as a pose (design §2 table).
enum Pose: String {
    case listening, heard, received, thinking, tool, generating, tts, muted, deaf, offline, sensesoff

    var image: Image { Image("avatar-" + rawValue) }
}

/// Bubble with continuous 19 pt corners and a smaller tail corner (design §2, decision Q1).
struct BubbleShape: Shape {
    var mine: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 19, small: CGFloat = tail ? 6 : 19
        let r = min(big, rect.height / 2)
        let s = min(small, r)
        let corners = mine
            ? RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: s, topTrailing: r)
            : RectangleCornerRadii(topLeading: r, bottomLeading: s, bottomTrailing: r, topTrailing: r)
        return UnevenRoundedRectangle(cornerRadii: corners, style: .continuous).path(in: rect)
    }
}

/// Haptics (design §2): recording started, crossing into cancel, send, cancel, failure. The
/// generators live for the app's lifetime and are prepared at touch-down, so the start haptic
/// (which follows the engine start) fires without the Taptic Engine's warm-up delay.
@MainActor
enum Haptics {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "ui.haptics") as? Bool ?? true }
    private static let startGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let cancelGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notice = UINotificationFeedbackGenerator()

    static func prepare() {
        guard enabled else { return }
        startGenerator.prepare(); cancelGenerator.prepare(); selection.prepare(); notice.prepare()
    }

    /// Recording really started: a light tap.
    static func start() {
        guard enabled else { return }
        startGenerator.impactOccurred()
        // Ready again for the release, which usually comes within a few seconds.
        cancelGenerator.prepare(); notice.prepare()
    }

    static func tick() { guard enabled else { return }; selection.selectionChanged(); selection.prepare() }
    /// Sent: the system success pattern (two taps), unlike the single start tap.
    static func send() { guard enabled else { return }; notice.notificationOccurred(.success) }
    /// Cancelled or too short: one firm tap.
    static func cancel() { guard enabled else { return }; cancelGenerator.impactOccurred() }
    static func warn() { guard enabled else { return }; notice.notificationOccurred(.warning) }
}

struct CircleButtonStyle: ButtonStyle {
    var fill: Color
    var fg: Color
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Palette.onBrand)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.brand))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// "0:06" for a duration in milliseconds.
func durationText(_ ms: Int) -> String {
    let s = max(0, Int((Double(ms) / 1000).rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "HH:mm", 24-hour, the same in every row and separator.
func hm(_ d: Date) -> String {
    let c = Calendar.current
    return String(format: "%02d:%02d", c.component(.hour, from: d), c.component(.minute, from: d))
}
