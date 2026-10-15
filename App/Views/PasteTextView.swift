// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The composer's text field. SwiftUI's `TextField` pastes text only; this one hands pasted images
/// to `onPasteImages` and pastes text as usual. Grows from one line to `maxLines`, then scrolls.
struct PasteTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines: Int
    /// Raw image data with its type, in pasteboard order.
    var onPasteImages: ([(data: Data, type: UTType)]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let v = PastingTextView()
        v.delegate = context.coordinator
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.onPasteImages = onPasteImages
        return v
    }

    func updateUIView(_ v: PastingTextView, context: Context) {
        v.onPasteImages = onPasteImages
        // Never overwrite while the input method is composing (pinyin in progress).
        if v.text != text, v.markedTextRange == nil { v.text = text }
        if focused, !v.isFirstResponder {
            DispatchQueue.main.async { v.becomeFirstResponder() }
        } else if !focused, v.isFirstResponder {
            DispatchQueue.main.async { v.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = (v.font ?? .preferredFont(forTextStyle: .body)).lineHeight * CGFloat(maxLines)
        let scrolls = fit > cap
        if v.isScrollEnabled != scrolls { DispatchQueue.main.async { v.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(fit, cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteTextView
        init(_ parent: PasteTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            v.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ v: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ v: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

final class PastingTextView: UITextView {
    var onPasteImages: (([(data: Data, type: UTType)]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let images = Self.pastedImages()
        guard !images.isEmpty else { return super.paste(sender) }
        onPasteImages?(images)
    }

    /// One image per pasteboard item, in the item's own format when it has one.
    private static func pastedImages() -> [(data: Data, type: UTType)] {
        let board = UIPasteboard.general
        guard board.hasImages else { return [] }
        var out: [(data: Data, type: UTType)] = []
        for (i, item) in board.items.enumerated() {
            let types = item.keys.compactMap(UTType.init).filter { $0.conforms(to: .image) }
            if let t = types.first, let d = board.data(forPasteboardType: t.identifier, inItemSet: IndexSet(integer: i))?.first {
                out.append((d, t))
            } else if let image = item.values.lazy.compactMap({ $0 as? UIImage }).first, let d = image.pngData() {
                out.append((d, .png))
            }
        }
        return out
    }
}
