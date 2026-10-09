// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import SwiftUI

/// First run (design §4.1): Tailscale login → find 多多 → add Passport (optional).
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule().fill(i <= step ? Palette.brand : Palette.hairline).frame(width: 22, height: 4)
                }
            }
            .padding(.top, 12)
            .accessibilityElement()
            .accessibilityLabel(String(localized: "第 \(step + 1) 步，共 3 步"))
            switch step {
            case 0: tailnetStep
            case 1:
                NavigationStack {
                    ConnectionEditor(mode: .onboarding) { step = 2 }
                }
            default: passportStep
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .onAppear { if model.tailnet.backend_state == "Running" { step = max(step, 1) } }
        .onChange(of: model.tailnet.backend_state) { _, s in if s == "Running", step == 0 { step = 1 } }
    }

    private var tailnetStep: some View {
        VStack(spacing: 16) {
            Spacer()
            AvatarView(pose: .offline, size: 120)
            Text(String(localized: "先连上你的网络")).font(.title.weight(.bold))
            Text(String(localized: "多多随身通过你的 Tailscale 网络找到多多，不经过公网，也不用装 VPN。"))
                .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            Label(String(localized: "登录后这台手机会作为节点 \(Tailnet.hostname) 出现在你的 tailnet 里，只登录一次。"), systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cell))
            if model.tailnet.backend_state == "Starting" || model.tailnet.backend_state == "NotStarted" {
                ProgressView(String(localized: "正在启动…")).font(.footnote)
            }
            Spacer()
            Button(String(localized: "登录 Tailscale")) { TailnetLogin.shared.start(model.tailnet) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.tailnet.auth_url == nil)
            Button(String(localized: "先体验")) { model.startTrying() }
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .accessibilityHint(String(localized: "不连接网络，用演示数据试用所有功能"))
            Link(String(localized: "什么是 Tailscale?"), destination: URL(string: "https://tailscale.com/kb/1151/what-is-tailscale")!)
                .font(.subheadline)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }

    private var passportStep: some View {
        VStack(spacing: 0) {
            PairingContent()
            Button(model.device.link == .ready ? String(localized: "完成") : String(localized: "跳过")) { model.onboarding = false }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
        }
    }
}
