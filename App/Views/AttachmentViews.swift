// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import ImageIO
import PocketCore
import QuickLook
import SwiftUI

/// Attachments by content key. The channel serves them immutable (`Cache-Control: immutable`), so
/// a file on disk never needs revalidation.
actor AttachmentCache {
    static let shared = AttachmentCache()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var inflight: [String: Task<URL, Error>] = [:]

    /// Local file for the attachment, downloading it once.
    func file(_ a: ChannelAttachment, settings: ChannelSettings) async throws -> URL {
        guard let sha = a.sha256 else { throw ChannelError.http(404, "no sha256") }
        let ext = (a.name as NSString).pathExtension
        let url = dir.appendingPathComponent(ext.isEmpty ? sha : "\(sha).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let t = inflight[sha] { return try await t.value }
        let t = Task<URL, Error> {
            let data = try await ChannelClient(settings: settings, tuning: PocketTuning.load()).attachment(a)
            try data.write(to: url, options: .atomic)
            return url
        }
        inflight[sha] = t
        defer { inflight[sha] = nil }
        return try await t.value
    }
}

/// Decodes an image file at display size (ImageIO thumbnail), not at full resolution.
func downsampled(_ url: URL, maxPixel: CGFloat) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: maxPixel]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
}

struct AttachmentView: View {
    @EnvironmentObject var model: AppModel
    let attachment: ChannelAttachment
    let mine: Bool
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var failed = false
    @State private var viewing = false
    @State private var previewing: URL?

    /// Thread thumbnail width in points.
    private let width: CGFloat = 220

    var body: some View {
        Group {
            if attachment.isInlineImage, attachment.sha256 != nil {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Palette.theirsFill
                        if failed { Image(systemName: "photo").foregroundStyle(Palette.tertiary) } else { ProgressView() }
                    }
                }
                .frame(width: width, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onTapGesture { if image != nil { viewing = true } }
                .task(id: attachment.sha256) { await loadImage() }
                .fullScreenCover(isPresented: $viewing) {
                    if let file { ImageViewer(url: file, name: attachment.name) }
                }
                .accessibilityLabel(String(localized: "图片 \(attachment.name)"))
                .accessibilityAddTraits(.isImage)
            } else {
                Button { Task { await openFile() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.title3)
                            .foregroundStyle(mine ? Palette.mineFill : Palette.brand)
                            .frame(width: 36, height: 44)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.cell))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(failed ? String(localized: "打不开 · 轻点重试") : ((attachment.name as NSString).pathExtension.uppercased()))
                                .font(.caption2).opacity(0.75)
                        }
                    }
                    .foregroundStyle(mine ? Palette.mineText : Palette.theirsText)
                    .padding(10)
                    .frame(maxWidth: 240, alignment: .leading)
                    .background(BubbleShape(mine: mine, tail: false).fill(mine ? Palette.mineFill : Palette.theirsFill))
                }
                .buttonStyle(.plain)
                .disabled(attachment.sha256 == nil)
                .quickLookPreview($previewing)
                .accessibilityLabel(String(localized: "文件 \(attachment.name)"))
            }
        }
    }

    private var imageHeight: CGFloat {
        guard let image, image.size.width > 0 else { return width * 0.75 }
        return min(width * 1.4, max(width * 0.5, width * image.size.height / image.size.width))
    }

    private var icon: String {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "zip", "gz": return "doc.zipper"
        case "txt", "md": return "doc.text"
        default: return attachment.mime.hasPrefix("image/") ? "photo" : "doc"
        }
    }

    private func loadImage() async {
        do {
            let url = try await AttachmentCache.shared.file(attachment, settings: model.settings)
            file = url
            // Long side 1.4 × width: the tallest uncropped thumbnail (see `imageHeight`).
            let px = width * UIScreen.main.scale * 1.4
            image = await Task.detached { downsampled(url, maxPixel: px) }.value
            failed = image == nil
        } catch {
            failed = true
        }
    }

    private func openFile() async {
        do {
            failed = false
            previewing = try await AttachmentCache.shared.file(attachment, settings: model.settings)
        } catch {
            failed = true
        }
    }
}

struct ImageViewer: View {
    let url: URL
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in
                        withAnimation { scale = 1 }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(String(localized: "图片 \(name)"))
            }
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle(fill: .white.opacity(0.2), fg: .white, size: 40))
                    .accessibilityLabel(String(localized: "关闭"))
                Spacer()
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(CircleButtonStyle(fill: .white.opacity(0.2), fg: .white, size: 40))
                    .accessibilityLabel(String(localized: "分享"))
            }
            .padding()
        }
    }
}
