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

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let img = UIImage(contentsOfFile: url.path) {
                ZoomableImage(image: img)
                    .ignoresSafeArea()
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

/// Pinch to zoom, pan, double-tap to toggle fit and 1:1. The zoom stays where the fingers leave it.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView(image: image) }
    func updateUIView(_ view: ZoomScrollView, context: Context) {}
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var fittedBounds: CGSize = .zero

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedBounds, bounds.width > 0, bounds.height > 0 else { return center() }
        fittedBounds = bounds.size
        let size = imageView.image?.size ?? .zero
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: size.width * fit, height: size.height * fit))
        contentSize = imageView.frame.size
        // Upper bound: one image pixel per screen pixel; past it there is no more detail to show.
        let pixels = (imageView.image?.scale ?? 1) * size.width
        let shown = imageView.frame.width * (window?.screen.scale ?? traitCollection.displayScale)
        minimumZoomScale = 1
        maximumZoomScale = max(1, pixels / shown)
        center()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    /// Keeps the image centred while it is smaller than the view.
    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView)
            let w = bounds.width / maximumZoomScale, h = bounds.height / maximumZoomScale
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
