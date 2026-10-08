// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// Ambient mode as a call (decision Q2): full screen, minimised to a pill in the conversation.
struct AmbientView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let a = model.ambient
        VStack(spacing: 0) {
            HStack {
                Button { model.ambientExpanded = false } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                }
                .foregroundStyle(Palette.secondary)
                .frame(width: 44, height: 44)
                .accessibilityLabel(String(localized: "收起到对话"))
                Spacer()
                VStack(spacing: 1) {
                    Text(String(localized: "多多")).font(.headline)
                    Text(String(localized: "环境模式 · \(hm(model.now))"))
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }
                Spacer()
                PassportChip()
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 8).layoutPriority(-2)
            // The dog gives way first: at large text sizes it shrinks so the status, captions
            // and the controls stay on screen.
            Rings(pose: model.presence.pose, live: a.phase == .listening || a.speaking, animate: !reduceMotion)
                .frame(maxWidth: 250, maxHeight: 250)
                .aspectRatio(1, contentMode: .fit)
                .layoutPriority(-1)
            VStack(spacing: 6) {
                Text(title).font(.title.weight(.bold)).foregroundStyle(Palette.text).lineLimit(1)
                if let step = toolStep {
                    // The working card's current step line (ToolLine rules, never raw input), one
                    // line as on the card.
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            if case .seatTaken = a.phase {
                Button(String(localized: "在这台手机上听")) { AmbientController.shared.takeover() }
                    .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220).padding(.top, 14)
            } else if a.phase == .deaf || isFailed {
                Button(String(localized: "重新打开")) { AmbientController.shared.reopen() }
                    .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220).padding(.top, 14)
            }

            if let caption {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "多多"), systemImage: "speaker.wave.2.fill")
                        .font(.caption).foregroundStyle(Palette.tertiary)
                    Text(caption)
                        .font(.body)
                        .foregroundStyle(Palette.theirsText)
                        .lineLimit(5)
                        .truncationMode(.head)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Palette.theirsFill))
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            if let heard = model.chat.lastHeard {
                HStack(spacing: 6) {
                    Image(systemName: "ear").font(.caption)
                    Text(heard).font(.footnote).lineLimit(2)
                }
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }
            if a.thermalWarning {
                Text(String(localized: "手机有点热，环境模式会更耗电")).font(.caption).foregroundStyle(Palette.attention).padding(.top, 8)
            }
            Spacer(minLength: 12).layoutPriority(-2)

            HStack(spacing: 0) {
                control(a.phase == .muted ? "mic.slash.fill" : "mic.slash", a.phase == .muted ? String(localized: "取消静音") : String(localized: "静音"),
                        fill: a.phase == .muted ? Palette.text : Palette.chip, fg: a.phase == .muted ? Palette.background : Palette.text) {
                    AmbientController.shared.setMuted(a.phase != .muted)
                }
                control("hand.raised.fill", String(localized: "别说了"), fill: a.speaking ? Palette.brand : Palette.chip,
                        fg: a.speaking ? Palette.onBrand : Palette.placeholder) {
                    AmbientController.shared.hush()
                }
                .disabled(!a.speaking)
                control("text.bubble", String(localized: "对话"), fill: Palette.chip, fg: Palette.text) { model.ambientExpanded = false }
                control("power", String(localized: "关闭"), fill: Color(uiColor: .systemRed), fg: .white) {
                    AmbientController.shared.turnOff()
                    model.ambientExpanded = false
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .background(Palette.background.ignoresSafeArea())
        .accessibilityAction(named: String(localized: "别说了")) { AmbientController.shared.hush() }
        .accessibilityAction(.magicTap) { AmbientController.shared.hush() }
    }

    private var isFailed: Bool { if case .failed = model.ambient.phase { true } else { false } }

    private func control(_ icon: String, _ label: String, fill: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(fg)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(fill))
                Text(label).font(.footnote).foregroundStyle(Palette.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var title: String {
        let a = model.ambient
        switch a.phase {
        case .off: return String(localized: "已关闭")
        case .starting: return String(localized: "正在打开麦克风…")
        case .muted: return String(localized: "已静音")
        case .seatTaken: return String(localized: "另一台设备在听")
        case .deaf: return String(localized: "听不到了")
        case .interrupted: return String(localized: "已暂停")
        case .failed: return String(localized: "出了问题")
        case .listening:
            if a.speaking { return String(localized: "正在说") }
            if let w = model.chat.working {
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
    private var toolStep: String? {
        guard model.ambient.phase == .listening, !model.ambient.speaking else { return nil }
        return model.chat.working?.toolLabel
    }

    private var subtitle: String {
        let a = model.ambient
        switch a.phase {
        case .muted: return String(localized: "房间听不到，声音不会离开手机")
        case .seatTaken: return String(localized: "同一个房间只能有一台设备在听")
        case .deaf: return String(localized: "房间没有收到声音")
        case .interrupted: return String(localized: "来电或其他声音占用了麦克风，结束后会接着听")
        case .failed(let why): return why
        case .starting: return a.route
        default:
            if a.speaking { return a.speakingFiller ? String(localized: "马上回答你") : String(localized: "说话就能打断它") }
            return "\(a.route) · \(a.aec ? String(localized: "回声消除已开") : String(localized: "回声消除未开"))"
        }
    }

    private var caption: String? {
        if let w = model.chat.working, w.phase == .streaming, !w.text.isEmpty { return w.text }
        guard model.ambient.speaking, !model.ambient.speakingFiller else { return nil }
        for r in model.chat.rows.reversed() {
            if case .provisional(let p, _) = r { return p.text }
            if case .duoduo(let d) = r { return d.text }
        }
        return nil
    }
}

/// The dog with level rings (design §4.7). The rings sample the mic level only while visible.
struct Rings: View {
    var pose: Pose
    var live: Bool
    var animate: Bool

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            TimelineView(.periodic(from: .now, by: LevelTrail.interval)) { _ in
                let level = live && animate ? CGFloat(meterLevel()) : 0
                ZStack {
                    Circle().fill(Palette.brandWash.opacity(0.55)).scaleEffect(0.86 + 0.14 * level)
                    Circle().fill(Palette.brandWash).scaleEffect(0.80 + 0.08 * level)
                    Circle().stroke(live ? Palette.brand : Palette.placeholder, lineWidth: 3).scaleEffect(0.76)
                    AvatarView(pose: pose, size: side * 0.72)
                }
                .frame(width: side, height: side)
                .animation(animate ? .easeOut(duration: LevelTrail.interval) : nil, value: level)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// Minimised ambient (decision Q2): under the nav bar while ambient runs.
struct AmbientPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let a = model.ambient
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: LevelTrail.interval)) { _ in
                MiniMeter(level: a.phase == .listening ? meterLevel() : 0)
            }
            .frame(width: 28, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.brand)
                Text(String(localized: "环境模式 · \(a.route) · \(a.aec ? String(localized: "回声消除已开") : String(localized: "回声消除未开"))"))
                    .font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if a.speaking {
                Button { AmbientController.shared.hush() } label: {
                    Label(String(localized: "别说了"), systemImage: "hand.raised.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(Palette.cell))
            }
            Button { AmbientController.shared.turnOff() } label: { Image(systemName: "power") }
                .buttonStyle(CircleButtonStyle(fill: Palette.attention, fg: .white, size: 28))
                .accessibilityLabel(String(localized: "关闭环境模式"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Palette.brandWash))
        .contentShape(Capsule())
        .onTapGesture { model.ambientExpanded = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "环境模式，\(phase)"))
        .accessibilityAddTraits(.isButton)
    }

    private var phase: String {
        let a = model.ambient
        switch a.phase {
        case .muted: return String(localized: "已静音")
        case .deaf: return String(localized: "听不到了")
        case .seatTaken: return String(localized: "另一台设备在听")
        case .interrupted: return String(localized: "已暂停")
        case .failed: return String(localized: "出了问题")
        case .starting: return String(localized: "正在打开…")
        default:
            if a.speaking { return String(localized: "正在说") }
            if let w = model.chat.working { return w.phase == .tool ? String(localized: "在查") : (w.phase == .streaming ? String(localized: "正在回复") : String(localized: "在想")) }
            return String(localized: "在听")
        }
    }
}

struct MiniMeter: View {
    var level: Float
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5) { i in
                let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]
                Capsule()
                    .fill(Palette.brand)
                    .frame(width: 3, height: max(4, 20 * shape[i] * CGFloat(0.25 + 0.75 * level)))
            }
        }
        .accessibilityHidden(true)
    }
}
