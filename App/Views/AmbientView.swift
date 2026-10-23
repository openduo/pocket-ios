// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// Ambient mode as a call (decision Q2): full screen, minimised to a pill in the conversation.
struct AmbientView: View {
    @EnvironmentObject var model: AppModel
    /// The conversation shown over the room, remembered across openings.
    @AppStorage("ambient.transcript") private var transcript = false

    private var size: CGFloat { transcript ? 52 : 64 }

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
                    // The clock redraws only this line, once a minute.
                    TimelineView(.everyMinute) { ctx in
                        Text(String(localized: "环境模式 · \(hm(ctx.date))"))
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
                PassportChip()
            }
            .padding(.horizontal, 12)

            if transcript {
                // The conversation over the room: the mark steps back to the top and the thread
                // takes the middle. Read only; typing is the conversation's job.
                LogoMark(mood: model.presence.mood)
                    .frame(width: 120, height: 120)
                Text(model.ambientTitle).font(.headline).foregroundStyle(Palette.text).lineLimit(1)
                takeBack(a)
                ThreadView()
                    // Rows fade in under the mark and out above the controls.
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                 .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.bottom, 8)
                    .transition(.opacity)
                thermal(a)
            } else {
                room(a)
            }

            HStack(spacing: 0) {
                AmbientControl.silence(a, size: size)
                AmbientControl.hush(a, size: size)
                AmbientControl(icon: transcript ? "text.bubble.fill" : "text.bubble",
                               label: transcript ? String(localized: "隐藏对话") : String(localized: "对话"),
                               fill: transcript ? Palette.text : Palette.chip, fg: transcript ? Palette.background : Palette.text,
                               size: size) {
                    withAnimation(.snappy) { transcript.toggle() }
                }
                AmbientControl.off(size: size) { model.ambientExpanded = false }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .background(Palette.background.ignoresSafeArea())
        .accessibilityAction(named: String(localized: "别说了")) { AmbientController.shared.hush() }
        .accessibilityAction(.magicTap) { AmbientController.shared.hush() }
    }

    /// The room alone: the mark, the state, and what is being said.
    @ViewBuilder private func room(_ a: AmbientSnapshot) -> some View {
        Spacer(minLength: 8).layoutPriority(-2)
        // The mark gives way first: at large text sizes it shrinks so the status, captions and
        // the controls stay on screen.
        LogoMark(mood: model.presence.mood)
            .frame(maxWidth: 280, maxHeight: 280)
            .aspectRatio(1, contentMode: .fit)
            .layoutPriority(-1)
        VStack(spacing: 6) {
            Text(model.ambientTitle).font(.title.weight(.bold)).foregroundStyle(Palette.text).lineLimit(1)
            if let step = model.ambientToolStep {
                // The working card's current step line (ToolLine rules, never raw input), one
                // line as on the card.
                Text(step)
                    .font(.subheadline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }
            Text(model.ambientSubtitle).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)

        takeBack(a)

        if let caption = model.ambientCaption {
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
        thermal(a)
        Spacer(minLength: 12).layoutPriority(-2)
    }

    /// The way back from a seat taken elsewhere or a failure.
    @ViewBuilder private func takeBack(_ a: AmbientSnapshot) -> some View {
        if case .seatTaken = a.phase {
            Button(String(localized: "在这台手机上听")) { AmbientController.shared.takeover() }
                .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220).padding(.top, 14)
        } else if a.phase == .deaf || model.ambientFailed {
            Button(String(localized: "重新打开")) { AmbientController.shared.reopen() }
                .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 220).padding(.top, 14)
        }
    }

    @ViewBuilder private func thermal(_ a: AmbientSnapshot) -> some View {
        if a.thermalWarning {
            Text(String(localized: "手机有点热，环境模式会更耗电")).font(.caption).foregroundStyle(Palette.attention).padding(.top, 8)
        }
    }
}

/// Minimised ambient (decision Q2): under the nav bar while ambient runs.
struct AmbientPill: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scene

    var body: some View {
        let a = model.ambient
        HStack(spacing: 10) {
            Group {
                // The meter ticks only while it has a level to show, on screen: ambient keeps the
                // app running behind the lock screen, and a timeline would keep ticking there.
                if a.phase == .listening, scene == .active {
                    TimelineView(.periodic(from: .now, by: LevelTrail.interval)) { _ in MiniMeter(level: meterLevel()) }
                } else {
                    MiniMeter(level: 0)
                }
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
        case .deaf: return String(localized: "听不到了")
        case .seatTaken: return String(localized: "另一台设备在听")
        case .interrupted: return String(localized: "已暂停")
        case .offline: return String(localized: "连不上")
        case .failed: return String(localized: "出了问题")
        case .starting: return String(localized: "正在打开…")
        default:
            if a.speaking { return String(localized: "正在说") }
            if let w = model.chat.working { return w.phase == .tool ? String(localized: "在查") : (w.phase == .streaming ? String(localized: "正在回复") : String(localized: "在想")) }
            return a.silent ? String(localized: "在听 · 静音") : String(localized: "在听")
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
