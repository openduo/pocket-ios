// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import UIKit
import UniformTypeIdentifiers

/// 多多 in the share sheet: copies the shared images, files and text into the App Group inbox,
/// opens the app, which puts them in the composer, and closes. Nothing is sent from here.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = String(localized: "正在交给多多…")
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        Task { await run() }
    }

    private func run() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        do {
            let dir = try ShareInbox.newShare()
            var share = ShareInbox.Share(text: nil, files: [])
            for (i, p) in providers.enumerated() {
                if let file = await Self.copyFile(p, index: i, into: dir) {
                    share.files.append(file)
                } else if let text = await Self.loadText(p) {
                    share.text = [share.text, text].compactMap { $0 }.joined(separator: "\n")
                }
            }
            guard !share.files.isEmpty || !(share.text ?? "").isEmpty else {
                ShareInbox.remove(dir)
                return fail(String(localized: "没有可以交给多多的内容"))
            }
            try ShareInbox.commit(share, in: dir)
        } catch {
            return fail(String(localized: "交给多多失败"))
        }
        openApp(ShareInbox.openURL)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func fail(_ text: String) {
        label.text = text
        let error = NSError(domain: "dev.openduo.pocket.share", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        extensionContext?.cancelRequest(withError: error)
    }

    /// Images first (a photo is shared as an image and as a file), then any other data except
    /// plain text and URLs, which go to the draft.
    private static func copyFile(_ p: NSItemProvider, index: Int, into dir: URL) async -> ShareInbox.File? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        guard let type = types.first(where: { $0.conforms(to: .image) })
            ?? types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }) else { return nil }
        let suggested = p.suggestedName
        return await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return c.resume(returning: nil) }
                // The provided file is deleted when this handler returns: copy it now.
                let name = suggested.map { n in
                    n.contains(".") ? n : n + "." + (type.preferredFilenameExtension ?? "")
                } ?? url.lastPathComponent
                let stored = "\(index)-\(url.lastPathComponent)"
                do {
                    try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(stored))
                    c.resume(returning: ShareInbox.File(file: stored, name: name, type: type.identifier))
                } catch {
                    c.resume(returning: nil)
                }
            }
        }
    }

    private static func loadText(_ p: NSItemProvider) async -> String? {
        for type in [UTType.url, UTType.plainText] where p.hasItemConformingToTypeIdentifier(type.identifier) {
            let item = try? await p.loadItem(forTypeIdentifier: type.identifier)
            if let u = item as? URL { return u.absoluteString }
            if let s = item as? String { return s }
            if let d = item as? Data, let s = String(data: d, encoding: .utf8) { return s }
        }
        return nil
    }

    /// Extensions have no `UIApplication.shared`; the application is reached through the
    /// responder chain and asked to open the app's URL.
    private func openApp(_ url: URL) {
        var r: UIResponder? = self
        while let cur = r {
            if let app = cur as? UIApplication {
                let sel = NSSelectorFromString("openURL:options:completionHandler:")
                guard let imp = app.method(for: sel) else { return }
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(imp, to: Open.self)(app, sel, url as NSURL, NSDictionary(), nil)
                return
            }
            r = cur.next
        }
    }
}
