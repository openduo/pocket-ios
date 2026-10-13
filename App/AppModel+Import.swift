// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import Foundation
import UIKit
import UniformTypeIdentifiers

/// Attachments that arrive from outside the composer's own pickers: the share extension's inbox
/// and the pasteboard.
extension AppModel {
    /// Image types the channel shows inline (`INLINE_ATTACHMENT_MIME`); other images become JPEG.
    static let inlineImageMIME: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Adds data as a draft chip, under the type's MIME.
    func addImported(name: String, type: UTType?, data: Data) {
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        if type?.conforms(to: .image) == true, let image = UIImage(data: data) {
            if Self.inlineImageMIME.contains(mime) {
                addAttachment(name: name, mime: mime, data: data, thumbnail: image)
            } else if let jpeg = image.jpegData(compressionQuality: Composer.photoJPEGQuality) {
                let jpgName = (name as NSString).deletingPathExtension + ".jpg"
                addAttachment(name: jpgName, mime: "image/jpeg", data: jpeg, thumbnail: image)
            }
            return
        }
        addAttachment(name: name, mime: mime, data: data, thumbnail: nil)
    }

    /// Moves complete shares from the extension's inbox into the composer: files as chips, text
    /// into the draft. Each share is removed once read.
    func importShares() {
        let shares = ShareInbox.pending()
        guard !shares.isEmpty else { return }
        for (dir, share) in shares {
            for f in share.files {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.file)) else { continue }
                addImported(name: f.name, type: UTType(f.type), data: data)
            }
            if let t = share.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                draftText = draftText.isEmpty ? t : draftText + "\n" + t
                // The draft is hidden in hold-to-talk mode.
                voiceInput = false
            }
            ShareInbox.remove(dir)
            AppLog.shared.log("share_imported", ["files": share.files.count, "text": share.text != nil])
        }
        ambientExpanded = false
    }
}
