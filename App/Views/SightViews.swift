// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import AVFoundation
import PocketCore
import SwiftUI

// Sight in the room (docs/design/sight.md): the camera control, the camera's state with the flip
// in a hand, and the viewfinder of the rear camera in a hand.

extension AppModel {
    /// What the camera is doing, in the room's words; nil when there is nothing to say.
    var sightLine: String? {
        switch ambient.sight {
        case .on: String(localized: "摄像头已开")
        case .hint: String(localized: "把手机半折立起来，多多就能看到房间")
        case .paused(.background): String(localized: "App 在后台，摄像头已暂停")
        case .paused(.taken): String(localized: "摄像头被其他应用占用，结束后自动恢复")
        case .paused(.hot): String(localized: "手机过热，摄像头已暂停")
        case .paused(.wrongHalf): String(localized: "摄像头在下半边，把手机转过来")
        case .denied: String(localized: "没有摄像头权限，去设置里打开")
        case .failed(.cameraTaken): String(localized: "摄像头被其他应用占用，结束后自动恢复")
        case .failed(.noH264): String(localized: "这台手机编不了多多要的视频格式，摄像头用不了")
        case .failed(.noCamera): String(localized: "这台手机没有这个摄像头")
        case .failed(.noFormat): String(localized: "这个摄像头拍不了多多要的画面大小")
        case .refused("nonconforming"): String(localized: "房间没接收这台手机的画面，摄像头已关")
        case .refused("unframed_channel"): String(localized: "房间的频道版本太旧，收不了这台手机的画面")
        case .refused(let reason): String(localized: "房间关了这台手机的摄像头：\(reason)")
        case .failed(.encoderFailed): String(localized: "视频编码出错，摄像头已停")
        case .off, .notOffered, .asking: nil
        }
    }
}

extension AmbientControl {
    /// 摄像头: a switch like 静音, filled while on. Without access it opens Settings.
    static func camera(_ a: AmbientSnapshot, size: CGFloat = 64) -> some View {
        let on = a.sight != .off
        return AmbientControl(icon: on ? "video.fill" : "video.slash", label: String(localized: "摄像头"),
                              fill: on ? Palette.text : Palette.chip, fg: on ? Palette.background : Palette.text,
                              size: size) {
            if a.sight == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            } else {
                SightController.shared.toggle()
            }
        }
        .accessibilityLabel(on ? String(localized: "关闭摄像头") : String(localized: "打开摄像头"))
    }
}

/// The camera's state under the room status: a green dot while frames leave the phone, the line,
/// and in a hand the flip between the front and the rear camera. No picture of the front camera:
/// it would only show the person to themselves.
struct SightStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.ambient.sight
        // The hint has its own place under the title.
        if s != .hint, let line = model.sightLine {
            HStack(spacing: 6) {
                if s.camera != nil { Circle().fill(.green).frame(width: 8, height: 8) }
                Text(line).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(2)
                    .multilineTextAlignment(.center)
                if model.ambient.sightInHand, let c = s.camera {
                    Button { SightController.shared.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.footnote.weight(.semibold))
                            .frame(width: 44, height: 32)
                    }
                    .foregroundStyle(Palette.text)
                    .accessibilityLabel(c == .rear ? String(localized: "换前置摄像头") : String(localized: "换后置摄像头"))
                }
            }
        }
    }
}

/// What the rear camera in a hand points at, in place of the mark: the user aims it.
struct SightViewfinder: View {
    static func shows(_ a: AmbientSnapshot) -> Bool { a.sightInHand && a.sight.camera == .rear }

    var body: some View {
        SightPreview(session: SightController.shared.session)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityLabel(String(localized: "后置摄像头画面"))
    }
}

/// The running camera's picture, level with the horizon.
private struct SightPreview: UIViewRepresentable {
    var session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView { PreviewView() }

    func updateUIView(_ v: PreviewView, context: Context) { v.show(session) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        func show(_ session: AVCaptureSession?) {
            preview.videoGravity = .resizeAspectFill
            // A paused camera keeps its session's last frame; only a new session replaces it.
            guard let session, preview.session !== session else { return }
            preview.session = session
            let device = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
            guard let device else { return }
            let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
            rotation = r
            level(r.videoRotationAngleForHorizonLevelPreview)
            observation = r.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] r, _ in
                DispatchQueue.main.async { self?.level(r.videoRotationAngleForHorizonLevelPreview) }
            }
        }

        private func level(_ angle: CGFloat) {
            guard let c = preview.connection, c.isVideoRotationAngleSupported(angle) else { return }
            c.videoRotationAngle = angle
        }
    }
}
