// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PhotosUI
import PocketCore
import SwiftUI
import UniformTypeIdentifiers

/// Mode toggle · hold-to-talk bar or growing text field · `+` · send (design §4.5, §4.6). Opens in
/// hold-to-talk; the keyboard toggle switches to text and back, and the choice is remembered.
struct Composer: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false

    var body: some View {
        VStack(spacing: 8) {
            if !model.chips.isEmpty { ChipsRow() }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    model.voiceInput.toggle()
                    focused = !model.voiceInput
                } label: {
                    Image(systemName: model.voiceInput ? "keyboard" : "mic")
                }
                .buttonStyle(CircleButtonStyle(fill: Palette.chip, fg: Palette.secondary, size: 38))
                .accessibilityLabel(model.voiceInput ? String(localized: "切换到键盘输入") : String(localized: "切换到按住说话"))

                if model.voiceInput {
                    HoldToTalkBar()
                } else {
                    TextField(String(localized: "发消息"), text: $model.draftText, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.body)
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Palette.cell))
                        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Palette.hairline, lineWidth: 0.5))
                        .submitLabel(.send)
                }

                Menu {
                    Button { showPhotos = true } label: { Label(String(localized: "照片"), systemImage: "photo") }
                    Button { showCamera = true } label: { Label(String(localized: "拍照"), systemImage: "camera") }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button { showFiles = true } label: { Label(String(localized: "文件"), systemImage: "doc") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.chip))
                }
                .accessibilityLabel(String(localized: "添加照片或文件"))

                // In hold-to-talk mode only attachments can be sent; a hidden draft stays a draft.
                if !model.chips.isEmpty || (!model.voiceInput && !model.draftText.isEmpty) {
                    Button { model.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(CircleButtonStyle(fill: Palette.brand, fg: Palette.onBrand, size: 38))
                        .disabled(!model.canSend)
                        .opacity(model.canSend ? 1 : 0.4)
                        .accessibilityLabel(String(localized: "发送"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Palette.background)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: nil, matching: .images)
        .onChange(of: photos) { _, items in
            photos = []
            for item in items { Task { await addPhoto(item) } }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            for u in urls { addFile(u) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let d = image.jpegData(compressionQuality: Self.photoJPEGQuality) {
                    model.addAttachment(name: String(localized: "拍照-\(stamp()).jpg"), mime: "image/jpeg", data: d, thumbnail: image)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// JPEG quality for photos the app converts (HEIC, camera): the channel renders JPEG inline but
    /// not HEIC (`INLINE_ATTACHMENT_MIME`). 0.9 is visually lossless for photos; chosen, no data.
    static let photoJPEGQuality: CGFloat = 0.9

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private func addPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let image = UIImage(data: data)
        let inline: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        if let mime = type?.preferredMIMEType, inline.contains(mime) {
            let ext = type?.preferredFilenameExtension ?? "jpg"
            await MainActor.run { model.addAttachment(name: String(localized: "照片-\(stamp()).\(ext)"), mime: mime, data: data, thumbnail: image) }
        } else if let image, let jpeg = image.jpegData(compressionQuality: Self.photoJPEGQuality) {
            await MainActor.run { model.addAttachment(name: String(localized: "照片-\(stamp()).jpg"), mime: "image/jpeg", data: jpeg, thumbnail: image) }
        }
    }

    private func addFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            model.toast = String(localized: "读不了这个文件")
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let thumb = mime.hasPrefix("image/") ? UIImage(data: data) : nil
        model.addAttachment(name: url.lastPathComponent, mime: mime, data: data, thumbnail: thumb)
    }
}

struct ChipsRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.chips) { chip in
                    ChipView(chip: chip)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
        }
    }
}

struct ChipView: View {
    @EnvironmentObject var model: AppModel
    let chip: DraftChip

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let t = chip.thumbnail {
                    Image(uiImage: t).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc").font(.title3)
                        Text(chip.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(Palette.secondary)
                    .padding(4)
                }
                switch chip.state {
                case .uploading:
                    Color.black.opacity(0.25)
                    ProgressView().tint(.white)
                case .failed:
                    Palette.attentionFill.opacity(0.85)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                case .uploaded:
                    EmptyView()
                }
            }
            .frame(width: 64, height: 64)
            .background(Palette.cell)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button { model.removeChip(chip.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 18))
                }
                .offset(x: 6, y: -6)
                .accessibilityLabel(String(localized: "移除 \(chip.name)"))
            }
            .onTapGesture { if case .failed = chip.state { model.upload(chip.id) } }
            if case .failed(let why) = chip.state {
                Text(why).font(.caption2).foregroundStyle(Palette.attention).lineLimit(2).frame(width: 84)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }

    private var a11y: String {
        switch chip.state {
        case .uploading: String(localized: "\(chip.name)，正在上传")
        case .uploaded: String(localized: "\(chip.name)，已上传")
        case .failed(let w): String(localized: "\(chip.name)，\(w)")
        }
    }
}

// MARK: hold-to-talk

/// The wide 按住说话 bar (WeChat-style). Holding records; the finger leaving the bar arms cancel,
/// coming back disarms it (design §4.6).
struct HoldToTalkBar: View {
    @EnvironmentObject var model: AppModel
    @State private var started: Date?

    var body: some View {
        // While held, the recording sheet draws this bar again on top (`HoldOverlay.replica`).
        Text(model.holdLive ? String(localized: "松开发送") : String(localized: "按住说话"))
            .font(.body.weight(.semibold))
            .foregroundStyle(model.holdLive ? Palette.onBrand : Palette.text)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(model.holdLive ? Palette.brand : model.holding ? Palette.chip : Palette.cell))
            .scaleEffect(model.holding ? HoldOverlay.pressedScale : 1)
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Palette.hairline, lineWidth: 0.5))
            .opacity(model.voiceAvailable ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { model.holdButtonFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in model.holdButtonFrame = f }
            })
            // UIKit touches, not a SwiftUI DragGesture: the press state is set in touchesBegan,
            // the earliest point a touch reaches the app.
            .overlay {
                if !UIAccessibility.isVoiceOverRunning {
                    HoldTouchArea(began: began, moved: moved, ended: ended)
                }
            }
            .accessibilityLabel(model.holding ? String(localized: "正在录音，轻点两下发送") : String(localized: "按住说话"))
            .accessibilityHint(String(localized: "轻点两下开始录音，再轻点两下发送"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { HoldToggle.shared.magicTap(model) }
            .accessibilityAction(.escape) { HoldToggle.shared.cancel(model) }
    }

    private func began(_ age: TimeInterval) {
        HoldTiming.shared.begin(eventAge: age)
        guard model.voiceAvailable else {
            model.toast = String(localized: "语音服务暂不可用")
            return
        }
        started = Date()
        if !model.beginHold() { started = nil }
    }

    private func moved(_ location: CGPoint) {
        guard model.holding else { return }
        // Only a crossing changes state, so a moving finger publishes nothing per event.
        let armed = !model.holdButtonFrame.contains(location)
        if armed != model.cancelArmed {
            model.cancelArmed = armed
            Haptics.tick()
        }
    }

    /// `cancelled`: the system took the touch (call, Control Center); nothing is sent.
    private func ended(_ cancelled: Bool) {
        guard let s = started else { return }
        started = nil
        let cancel = cancelled || model.cancelArmed
        model.cancelArmed = false
        model.endHold(send: !cancel, heldFor: Date().timeIntervalSince(s))
    }
}

/// Touch surface of the hold bar. Reports touch-down from `touchesBegan` with the touch's age
/// (its hardware timestamp against now, both on the `systemUptime` clock), moves in window
/// coordinates (the same space as SwiftUI's `.global`), and the end. One finger only.
struct HoldTouchArea: UIViewRepresentable {
    var began: (TimeInterval) -> Void
    var moved: (CGPoint) -> Void
    var ended: (Bool) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        v.isExclusiveTouch = true
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) {
        v.began = began
        v.moved = moved
        v.ended = ended
    }

    final class TouchView: UIView {
        var began: ((TimeInterval) -> Void)?
        var moved: ((CGPoint) -> Void)?
        var ended: ((Bool) -> Void)?
        private weak var tracked: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracked == nil, let t = touches.first else { return }
            tracked = t
            began?(max(0, ProcessInfo.processInfo.systemUptime - t.timestamp))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = tracked, touches.contains(t) else { return }
            moved?(t.location(in: nil))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = tracked, touches.contains(t) else { return }
            tracked = nil
            ended?(false)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = tracked, touches.contains(t) else { return }
            tracked = nil
            ended?(true)
        }
    }
}

/// VoiceOver / Switch Control alternative to holding (design §4.6): toggle, Magic Tap, escape.
@MainActor
final class HoldToggle {
    static let shared = HoldToggle()
    private var started: Date?

    func magicTap(_ model: AppModel) {
        if model.holding {
            model.endHold(send: true, heldFor: Date().timeIntervalSince(started ?? Date()))
            started = nil
        } else {
            if model.beginHold() { started = Date() }
        }
    }

    func cancel(_ model: AppModel) {
        guard model.holding else { return }
        model.endHold(send: false, heldFor: AppModel.holdMinimum)
        started = nil
    }
}

/// The recording sheet (design screens `hold-record`, `hold-cancel`). The hold button is drawn again at
/// its own frame, under the finger; the middle of the sheet shows the timer and waveform, or, with
/// the finger off the button, the cancel target.
struct HoldOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var levels = LevelTrail()

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            let button = model.holdButtonFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.28)
                VStack(spacing: 18) {
                    // Both stay laid out so crossing the boundary never moves the sheet.
                    ZStack {
                        recording.opacity(model.cancelArmed ? 0 : 1)
                        cancelTarget.opacity(model.cancelArmed ? 1 : 0)
                    }
                    .animation(.easeOut(duration: 0.15), value: model.cancelArmed)
                    Text(model.cancelArmed ? String(localized: "移回按钮继续录音") : model.holdLive ? String(localized: "松开发送 · 手指移出按钮取消") : String(localized: "麦克风就绪后会轻震一下"))
                        .font(.footnote.weight(model.cancelArmed ? .semibold : .regular))
                        .foregroundStyle(model.cancelArmed ? Palette.attention : Palette.secondary)
                    replica
                        .frame(width: button.width, height: button.height)
                        .padding(.leading, button.minX)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 28)
                .padding(.bottom, max(0, g.size.height - button.maxY))
                .frame(width: g.size.width)
                .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .fill(Palette.cell))
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .transition(.move(edge: .bottom))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.cancelArmed ? String(localized: "松手取消") : model.holdLive ? String(localized: "正在录音") : String(localized: "准备中"))
        .onChange(of: model.holdLive) { _, live in
            // "Speak now": no haptic at the touch, one light tap when recording starts.
            guard live else { return }
            Haptics.start()
            HoldTiming.shared.mark("haptic")
        }
    }

    /// Preparing (touch-down until the input captures): 「准备中…」 over dimmed placeholder bars
    /// that breathe, no timer. Live: timer and the mic waveform. The waveform samples the mic
    /// level at display rate only. Both stay laid out, so the switch never moves the sheet.
    private var recording: some View {
        TimelineView(.periodic(from: .now, by: LevelTrail.interval)) { ctx in
            let live = model.holdLive
            let _ = live ? () : levels.reset()
            let _ = live ? levels.sample(meterLevel()) : ()
            let _ = HoldTiming.shared.mark("first_tick")
            let _ = HoldTiming.shared.mark(live ? "live_drawn" : "preparing_drawn")
            let _ = live && (levels.values.last ?? 0) > 0 ? HoldTiming.shared.mark("first_waveform") : ()
            VStack(spacing: 10) {
                ZStack {
                    Text(durationText(live ? Int(ctx.date.timeIntervalSince(model.holdStartedAt) * 1000) : 0))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.text)
                        .opacity(live ? 1 : 0)
                    Text(String(localized: "准备中…"))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(Palette.tertiary)
                        .opacity(live ? 0 : 1)
                }
                ZStack {
                    Waveform(values: levels.values, color: Palette.brand)
                        .opacity(live ? 1 : 0)
                    Waveform(values: Self.placeholder, color: Palette.tertiary)
                        .opacity(live ? 0 : Self.breath(ctx.date, still: reduceMotion))
                }
                .frame(height: 44)
                .padding(.horizontal, 30)
            }
            .animation(.easeOut(duration: Self.liveFade), value: live)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Aesthetic, chosen by eye: preparing → live cross-fade.
    static let liveFade: Double = 0.12
    /// Aesthetic: one breath of the placeholder bars, and its opacity range (dimmed throughout).
    static let breathPeriod: Double = 1.1
    static let breathRange: ClosedRange<Double> = 0.25...0.6

    /// Flat placeholder bars, a quarter of the waveform's height.
    static let placeholder = [Float](repeating: 0.25, count: LevelTrail.count)

    /// Placeholder opacity at `t`; Reduce Motion holds it still at the middle of the range.
    static func breath(_ t: Date, still: Bool) -> Double {
        let mid = (breathRange.lowerBound + breathRange.upperBound) / 2
        if still { return mid }
        let half = (breathRange.upperBound - breathRange.lowerBound) / 2
        return mid + half * sin(2 * .pi * t.timeIntervalSinceReferenceDate / breathPeriod)
    }

    /// The cancel target: the finger is off the button, so letting go cancels.
    private var cancelTarget: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Palette.onBrand)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Palette.attention))
            Text(String(localized: "松手取消"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.attention)
        }
    }

    /// The hold button under the finger. Pressed from the touch on (scaled down, darker); while
    /// preparing it keeps its idle label on a darkened fill, live it turns teal 「松开发送」, and
    /// off the button it greys.
    private var replica: some View {
        let live = model.holdLive, off = model.cancelArmed
        return Text(off || !live ? String(localized: "按住说话") : String(localized: "松开发送"))
            .font(.body.weight(.semibold))
            .foregroundStyle(off ? Palette.tertiary : live ? Palette.onBrand : Palette.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(off ? Palette.chip : live ? Palette.brand : Palette.chip))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(Color.black.opacity(!off && !live ? Self.pressedShade : 0)))
            .scaleEffect(off ? 1 : Self.pressedScale)
    }

    /// Aesthetic, chosen by eye: the pressed button, like a system button held down.
    static let pressedScale: CGFloat = 0.97
    static let pressedShade: Double = 0.12
}

/// Recent mic levels for the waveform, sampled only while the sheet is visible.
final class LevelTrail {
    /// Sampling period of the waveform and meters: display only, foreground only.
    static let interval: TimeInterval = 0.05
    static let count = 48
    private(set) var values = [Float](repeating: 0, count: LevelTrail.count)

    func sample(_ v: Float) {
        values.removeFirst()
        values.append(v)
    }

    func reset() {
        if values.contains(where: { $0 != 0 }) { values = [Float](repeating: 0, count: LevelTrail.count) }
    }
}

struct Waveform: View {
    var values: [Float]
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let n = values.count
            let w = size.width / CGFloat(n)
            for (i, v) in values.enumerated() {
                let h = max(3, CGFloat(v) * size.height)
                let r = CGRect(x: CGFloat(i) * w + w * 0.25, y: (size.height - h) / 2, width: w * 0.5, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w * 0.25), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Camera capture (UIKit; SwiftUI has no camera view).
struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            done(nil)
            picker.dismiss(animated: true)
        }
    }
}
