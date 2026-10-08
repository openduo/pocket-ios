// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import SwiftUI

/// Settings › 关于多多随身: version and the licences of the code bundled in the app.
struct AboutView: View {
    let version: String

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "版本"), value: version)
            }
            Section {
                NavigationLink(String(localized: "开源许可")) { LicensesView() }
            } footer: {
                Text(String(localized: "代码以 FSL-1.1-Apache-2.0 发布。应用图标、多多 / DuoDuo 与 OpenDuo 名称不在开源许可范围内。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.grouped.ignoresSafeArea())
        .navigationTitle(String(localized: "关于多多随身"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The bundled NOTICE, LICENSE and THIRD_PARTY_NOTICES.md as plain text. The notices file is
/// about 100 KB, so it is split at its headings and laid out lazily.
struct LicensesView: View {
    private let chunks: [String] = LicensesView.load()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(chunks.indices, id: \.self) { i in
                    Text(chunks[i])
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(String(localized: "开源许可"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func load() -> [String] {
        func text(_ name: String, _ ext: String?) -> String? {
            Bundle.main.url(forResource: name, withExtension: ext).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        var out: [String] = []
        for (name, ext) in [("NOTICE", nil), ("THIRD_PARTY_NOTICES", "md"), ("LICENSE", nil)] as [(String, String?)] {
            guard let t = text(name, ext) else { continue }
            out += t.components(separatedBy: "\n### ").enumerated().map { $0.offset == 0 ? $0.element : "### " + $0.element }
        }
        return out.isEmpty ? [String(localized: "许可文件缺失。")] : out
    }
}
