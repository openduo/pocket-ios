// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

// The room as the layouts draw it inline (docs/design/iphone-duo.md): the big display read from a
// distance, the column beside 多多 in landscape, and the band it folds into. The full-screen call
// view (AmbientView) uses the same text and controls.

extension AppModel {
    var ambientFailed: Bool { if case .failed = ambient.phase { true } else { false } }

    var ambientTitle: String {
        let a = ambient
        switch a.phase {
        case .off: return String(localized: "已关闭")
        case .starting: return String(localized: "正在打开麦克风…")
        case .seatTaken: return String(localized: "另一台设备在听")
        case .deaf: return String(localized: "听不到了")
        case .interrupted: return String(localized: "已暂停")
        case .offline: return String(localized: "连不上")
        case .failed: return String(localized: "出了问题")
        case .listening:
            if a.speaking { return String(localized: "正在说") }
            if let w = chat.working {
                switch w.phase {
                case .thinking, .received: return String(localized: "在想")
                case .tool: return String(localized: "在查")
                case .streaming: return String(localized: "正在说")
                }
            }
            return a.pressMuted ? String(localized: "按键说话中") : String(localized: "在听")
        }
    }

    /// 「Bash Show disk space」 under 在查, while a tool runs and nothing is being said.
    var ambientToolStep: String? {
        guard ambient.phase == .listening, !ambient.speaking else { return nil }
        return chat.working?.toolLabel
    }

    var ambientSubtitle: String {
        let a = ambient
        switch a.phase {
        case .seatTaken: return String(localized: "同一个房间只能有一台设备在听")
        case .deaf: return String(localized: "房间没有收到声音")
        case .interrupted: return String(localized: "来电或其他声音占用了麦克风，结束后会接着听")
        case .offline: return String(localized: "连不上房间，已停止收音；连上后打开 App 会接着听")
        case .failed(let why): return why
        case .starting: return a.route
        default:
            if a.silent { return String(localized: "已静音：还在听，回复只显示在屏幕上") }
            if a.speaking { return a.speakingFiller ? String(localized: "马上回答你") : String(localized: "说话就能打断它") }
            return "\(a.route) · \(a.aec ? String(localized: "回声消除已开") : String(localized: "回声消除未开"))"
        }
    }

    var ambientCaption: String? {
        if let w = chat.working, w.phase == .streaming, !w.text.isEmpty { return w.text }
        guard ambient.speaking, !ambient.speakingFiller else { return nil }
        for r in chat.rows.reversed() {
            if case .provisional(let p, _) = r { return p.text }
            if case .duoduo(let d) = r { return d.text }
        }
        return nil
    }

    /// Under the mark: the ambient state, or how to talk when ambient is off.
    var roomStatus: String {
        if ambient.isOn { return ambientTitle }
        if chat.working != nil { return presence.subtitle }
        return device.link == .ready ? String(localized: "按住 Passport 说话") : String(localized: "环境模式关着")
    }

    /// The large text: what is being said, the current step, or the last answer.
    var roomText: (question: String?, text: String) {
        if let c = ambientCaption { return (nil, c) }
        if let step = ambientToolStep { return (nil, step) }
        if let x = LastExchange.from(chat.rows) {
            let q = x.question.map { x.mine ? String(localized: "你：\($0)") : $0 }
            return (q, x.answer)
        }
        return (nil, String(localized: "我在，随时说"))
    }
}

/// One round control with its label: the call view's row, the room column, the tabletop row and the
/// tent.
struct AmbientControl: View {
    var icon: String
    var label: String
    var fill: Color
    var fg: Color
    var size: CGFloat = 64
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(fg)
                    .frame(width: size, height: size)
                    .background(Circle().fill(fill))
                Text(label).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                    // Large text sizes shrink the label within its column, apart from its neighbours,
                    // rather than cut it.
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    static func silence(_ a: AmbientSnapshot, size: CGFloat = 64) -> AmbientControl {
        AmbientControl(icon: a.silent ? "speaker.slash.fill" : "speaker.slash",
                       label: a.silent ? String(localized: "取消静音") : String(localized: "静音"),
                       fill: a.silent ? Palette.text : Palette.chip, fg: a.silent ? Palette.background : Palette.text,
                       size: size) { AmbientController.shared.setSilent(!a.silent) }
    }

    static func hush(_ a: AmbientSnapshot, size: CGFloat = 64) -> some View {
        AmbientControl(icon: "hand.raised.fill", label: String(localized: "别说了"),
                       fill: a.speaking ? Palette.brand : Palette.chip, fg: a.speaking ? Palette.onBrand : Palette.placeholder,
                       size: size) { AmbientController.shared.hush() }
            .disabled(!a.speaking)
    }

    static func off(size: CGFloat = 64, then: @escaping () -> Void = {}) -> AmbientControl {
        AmbientControl(icon: "power", label: String(localized: "关闭"), fill: Color(uiColor: .systemRed), fg: .white,
                       size: size) { AmbientController.shared.turnOff(); then() }
    }
}

/// 静音 · 别说了 · 关闭 while ambient is on; 开环境模式 while it is off; the way out of a seat
/// taken or a failure. A layout's own controls (会话, 对话) join the row as equal members.
struct RoomControls<Leading: View, Trailing: View>: View {
    @EnvironmentObject var model: AppModel
    var size: CGFloat = 52
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let a = model.ambient
        HStack(spacing: 0) {
            leading
            if case .seatTaken = a.phase {
                AmbientControl(icon: "ear", label: String(localized: "在这台手机上听"), fill: Palette.brand, fg: Palette.onBrand,
                               size: size) { AmbientController.shared.takeover() }
                AmbientControl.off(size: size)
            } else if a.phase == .deaf || model.ambientFailed {
                AmbientControl(icon: "arrow.clockwise", label: String(localized: "重新打开"), fill: Palette.brand, fg: Palette.onBrand,
                               size: size) { AmbientController.shared.reopen() }
                AmbientControl.off(size: size)
            } else if a.isOn {
                AmbientControl.silence(a, size: size)
                AmbientControl.hush(a, size: size)
                AmbientControl.off(size: size)
            } else {
                AmbientControl(icon: "waveform", label: String(localized: "开环境模式"), fill: Palette.chip, fg: Palette.brand,
                               size: size) { model.ambientTapped(expand: false) }
                    .opacity(model.voiceAvailable ? 1 : 0.4)
            }
            trailing
        }
    }
}

extension RoomControls where Leading == EmptyView, Trailing == EmptyView {
    init(size: CGFloat = 52) { self.init(size: size) {} trailing: {} }
}

/// The room read from a distance: the mark beside the last question and the answer in large type.
/// The tent, the upright half on tabletop and the top half open flat. In the tent it carries its own
/// controls; elsewhere they sit within reach below it.
struct BigRoom: View {
    @EnvironmentObject var model: AppModel
    var controls = false
    var onThread: () -> Void = {}

    var body: some View {
        let t = model.roomText
        HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 10) {
                LogoMark(mood: model.presence.mood).frame(width: 210, height: 210)
                Text(model.roomStatus).font(.headline).foregroundStyle(Palette.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 210)
            VStack(alignment: .leading, spacing: 14) {
                if let q = t.question {
                    Text(q).font(.title3).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Text(t.text).font(.system(size: 34, weight: .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(5).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if controls { tentControls }
            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .accessibilityElement(children: .contain)
    }

    /// The same round controls as the tabletop row, so four of them fit beside the mark: labelled
    /// pills need more width than the text column has once ambient is on.
    private var tentControls: some View {
        RoomControls {} trailing: {
            AmbientControl(icon: "text.bubble", label: String(localized: "对话"), fill: Palette.chip, fg: Palette.text,
                           size: 52, action: onThread)
        }
    }
}

/// The room in the tall right pane of the inner display in landscape: the same mark and text as
/// `BigRoom`, stacked, with the controls under the content they act on.
struct RoomColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let t = model.roomText
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            LogoMark(mood: model.presence.mood).frame(width: 185, height: 185)
            Text(model.roomStatus).font(.headline).foregroundStyle(Palette.secondary)
            VStack(alignment: .leading, spacing: 12) {
                if let q = t.question {
                    Text(q).font(.title3).foregroundStyle(Palette.secondary).lineLimit(2)
                }
                Text(t.text).font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(6).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            RoomControls()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}

/// The room pushed up into a band: the mark, its state and the line being said, and the controls
/// as small icons.
struct RoomBand: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let a = model.ambient
        HStack(spacing: 12) {
            LogoMark(mood: model.presence.mood).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.roomStatus).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brand)
                Text(model.roomText.text).font(.footnote).foregroundStyle(Palette.text).lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                Button { AmbientController.shared.setSilent(!a.silent) } label: {
                    Image(systemName: a.silent ? "speaker.slash.fill" : "speaker.slash")
                }
                .accessibilityLabel(a.silent ? String(localized: "取消静音") : String(localized: "静音"))
                Button { AmbientController.shared.hush() } label: { Image(systemName: "hand.raised.fill") }
                    .disabled(!a.speaking)
                    .accessibilityLabel(String(localized: "别说了"))
                Button { AmbientController.shared.turnOff() } label: { Image(systemName: "power").foregroundStyle(.red) }
                    .accessibilityLabel(String(localized: "关闭环境模式"))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(Palette.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.brandWash.opacity(0.6))
    }
}
