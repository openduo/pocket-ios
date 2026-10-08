// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI

/// Passport status, latest reply, device facts and actions (design §4.8).
struct PassportSheet: View {
    /// Pushed from Settings (already inside a navigation stack) rather than presented as a sheet.
    var pushed = false
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var confirmForget = false

    private var paired: Bool { UserDefaults.standard.string(forKey: Keys.savedPeripheral) != nil || model.device.link == .ready }

    var body: some View {
        Group {
            if pushed {
                content
            } else {
                NavigationStack { content }
            }
        }
        .onAppear {
            #if DEBUG
            if Demo.screen == "passport-pair" { pairing = true }
            #endif
        }
    }

    private var content: some View {
        Group {
            if !paired || pairing {
                PairingContent()
            } else {
                details
            }
        }
        .navigationTitle(!paired || pairing ? String(localized: "添加 Passport") : "Passport")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pushed { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
            if pairing { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "返回")) { pairing = false } } }
        }
        .background(Palette.grouped.ignoresSafeArea())
    }

    private var details: some View {
        let d = model.device
        return List {
            Section {
                HStack(spacing: 14) {
                    DeviceDrawing(text: nil).frame(width: 58, height: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.deviceName ?? "Passport").font(.title3.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle().fill(d.link == .ready ? Palette.ok : Palette.placeholder).frame(width: 7, height: 7)
                            Text(linkText).font(.footnote)
                        }
                        .foregroundStyle(d.link == .ready ? Palette.ok : Palette.secondary)
                        if let at = d.lastPressAt {
                            Text(String(localized: "最近一次按键 \(hm(at))"))
                                .font(.caption).foregroundStyle(Palette.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
                if let hint = linkHint {
                    Label(hint.0, systemImage: hint.1).font(.footnote).foregroundStyle(Palette.attention)
                    if d.link == .off || d.link == .unauthorized {
                        Button(String(localized: "打开设置")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                }
            }
            Section {
                HStack(spacing: 10) {
                    stat(String(localized: "电量"), d.battery.map { "\($0)%" } ?? "—", nil)
                    stat(String(localized: "充电"), chargingText, d.charging == .unknown && d.battery != nil ? String(localized: "本机无法检测") : nil)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section(String(localized: "Passport 正在显示")) {
                if let r = d.lastReply {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(localized: "多多")).font(.caption).foregroundStyle(Palette.tertiary)
                            Spacer()
                            Text(d.link == .ready ? String(localized: "已送达设备") : String(localized: "等待连接后发送")).font(.caption).foregroundStyle(Palette.tertiary)
                        }
                        Text(r).font(.subheadline).lineLimit(6)
                    }
                } else {
                    Text(String(localized: "还没有回复")).foregroundStyle(Palette.tertiary)
                }
            }
            Section(String(localized: "设备")) {
                LabeledContent(String(localized: "固件"), value: d.info?.firmware ?? "—")
                LabeledContent(String(localized: "链路协议"), value: d.info.map { "\($0.protoMajor).\($0.protoMinor)" } ?? "—")
                LabeledContent {
                    Text(d.info.map { $0.preroll ? String(localized: "开") : String(localized: "关") } ?? "—")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "预录音"))
                        Text(String(localized: "在 Passport 的设置里切换")).font(.caption).foregroundStyle(Palette.tertiary)
                    }
                }
                if let e = d.versionError {
                    Text(String(localized: "版本不匹配：\(e)。请更新多多随身或设备固件。")).font(.footnote).foregroundStyle(Palette.attention)
                }
            }
            Section {
                Button(String(localized: "重新配对")) { pairing = true }
                ShareLink(String(localized: "导出 Passport 日志"), items: AppLog.shared.exportFiles(extra: [Tailnet.shared.tsnetLog].compactMap { $0 }))
                Button(String(localized: "忘记此设备"), role: .destructive) { confirmForget = true }
            } footer: {
                Text(String(localized: "忘记后，还需要在 iPhone 的「设置 › 蓝牙」里忽略这台设备，才能重新配对。"))
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog(String(localized: "忘记这台 Passport？"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button(String(localized: "忘记此设备"), role: .destructive) { PocketEngine.shared.link.forget() }
        } message: {
            Text(String(localized: "App 会重新开始寻找设备。系统里的配对记录需要在 iPhone 设置中删除。"))
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
                if let note { Text(note).font(.caption2).foregroundStyle(Palette.tertiary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cell))
        .accessibilityElement(children: .combine)
    }

    private var chargingText: String {
        switch model.device.charging {
        case .yes: String(localized: "充电中")
        case .no: String(localized: "未充电")
        case .unknown: String(localized: "未知")
        }
    }

    private var linkText: String {
        let d = model.device
        if d.versionError != nil { return String(localized: "版本不匹配") }
        switch d.link {
        case .ready: return String(localized: "已连接 · 加密配对")
        case .pairing: return String(localized: "正在配对")
        case .connecting, .connected: return String(localized: "正在连接")
        case .scanning: return String(localized: "正在寻找")
        case .off: return String(localized: "蓝牙关闭")
        case .unauthorized: return String(localized: "没有蓝牙权限")
        case .failed: return String(localized: "连接失败")
        }
    }

    private var linkHint: (String, String)? {
        switch model.device.link {
        case .off: (String(localized: "蓝牙已关闭，Passport 连不上"), "antenna.radiowaves.left.and.right.slash")
        case .unauthorized: (String(localized: "需要蓝牙权限才能连接 Passport"), "lock")
        case .connecting, .scanning: (String(localized: "靠近手机会自动连上"), "dot.radiowaves.left.and.right")
        case .failed: (model.device.linkDetail ?? String(localized: "连接失败"), "exclamationmark.triangle")
        default: nil
        }
    }
}

/// Pairing (design screen `passport-pair`): iOS shows the numeric-comparison alert; this explains it.
struct PairingContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DeviceDrawing(text: String(localized: "配对码")).frame(width: 120, height: 150).padding(.top, 20)
                Text(String(localized: "核对两边的数字")).font(.title2.weight(.bold))
                Text(String(localized: "iPhone 弹窗里的配对码和 Passport 屏幕上的一致时，先在 Passport 上按 OK，再在 iPhone 上点「配对」。"))
                    .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "附近的设备")).font(.caption).foregroundStyle(Palette.tertiary)
                    HStack(spacing: 10) {
                        Image(systemName: "candybarphone").foregroundStyle(Palette.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.device.deviceName ?? String(localized: "正在寻找 Passport…")).font(.subheadline.weight(.semibold))
                            Text(stateText).font(.caption).foregroundStyle(Palette.tertiary)
                        }
                        Spacer()
                        if model.device.link == .ready {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        } else {
                            ProgressView()
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cell))
                }
                Text(String(localized: "如果没有出现：长按 Passport 的 UP 键打开设置，选「重新配对」。以前配对过的，先在 iPhone 的「设置 › 蓝牙」里忽略这台设备。"))
                    .font(.caption).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 24)
        }
    }

    private var stateText: String {
        switch model.device.link {
        case .ready: String(localized: "已配对")
        case .pairing: String(localized: "等待确认")
        case .connecting, .connected: String(localized: "正在连接")
        case .off: String(localized: "蓝牙已关闭")
        case .unauthorized: String(localized: "没有蓝牙权限")
        default: String(localized: "保持 Passport 在手边")
        }
    }
}

/// A simple drawing of the Passport: rounded body, screen, OK key.
struct DeviceDrawing: View {
    var text: String?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.18, style: .continuous).fill(Color(white: 0.12))
                RoundedRectangle(cornerRadius: w * 0.08, style: .continuous)
                    .fill(Color(white: 0.2))
                    .frame(width: w * 0.8, height: h * 0.55)
                    .overlay {
                        if let text {
                            VStack(spacing: 2) {
                                Text(text).font(.system(size: w * 0.07)).foregroundStyle(.white.opacity(0.7))
                                Text("••• •••").font(.system(size: w * 0.16, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Color(uiColor: UIColor(hex: 0x1FD9DE)))
                            }
                        } else {
                            Image("avatar-listening").resizable().scaledToFit().padding(w * 0.12)
                                .environment(\.colorScheme, .dark)
                        }
                    }
                    .padding(.top, h * 0.08)
                Circle().fill(Color(white: 0.28)).frame(width: w * 0.22).offset(y: h * 0.72)
            }
        }
        .accessibilityHidden(true)
    }
}
