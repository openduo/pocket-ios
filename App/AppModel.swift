// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

import PocketCore
import SwiftUI
import UIKit

/// One attachment in the composer. Upload starts when the chip is added (design §4.5).
struct DraftChip: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case uploaded(ChannelAttachment)
        case failed(String)
    }

    let id = UUID()
    var name: String
    var mime: String
    var size: Int
    var thumbnail: UIImage?
    var data: Data
    var state = State.uploading

    static func == (a: DraftChip, b: DraftChip) -> Bool { a.id == b.id && a.state == b.state }
}

/// UI state on the main actor. Engines publish snapshots here only while the app is active:
/// SwiftUI work in the background got the app killed for CPU (measured on the iPhone XS Max).
@MainActor
final class AppModel: ObservableObject {
    @Published var chat = ChatSnapshot()
    @Published var ambient = AmbientSnapshot()
    @Published var device = EngineSnapshot()
    @Published var tailnet = TailnetStatus.unknown
    @Published var settings = ChannelSettings.load()
    @Published var ambientExpanded = false
    @Published var draftText = ""
    /// The DuoDuo message the next typed send replies to (long-press 「回复」).
    @Published var quote: String?
    /// Counts the user's own sends; the thread follows each one to the end.
    @Published var sentCount = 0
    @Published var chips: [DraftChip] = []
    @Published var holding = false
    /// The finger left the hold button while recording: releasing now cancels.
    @Published var cancelArmed = false
    /// Global frame of the composer's hold button. The finger outside it arms cancel; the
    /// recording sheet draws the button again at this frame so the boundary is what the user sees.
    @Published var holdButtonFrame: CGRect = .zero
    /// Composer input: hold-to-talk (default) or keyboard. The last choice survives relaunch.
    @Published var voiceInput: Bool = UserDefaults.standard.object(forKey: Keys.composerVoice) as? Bool ?? true {
        didSet { if persistComposerMode { UserDefaults.standard.set(voiceInput, forKey: Keys.composerVoice) } }
    }
    /// Off for design fixtures, which must not change the stored choice.
    var persistComposerMode = true
    /// When the current hold's recording started (the input began capturing); the touch time
    /// until then.
    private(set) var holdStartedAt = Date()
    /// The current hold is recording: the engine's input is capturing.
    @Published private(set) var holdLive = false
    /// Tells a late engine callback from an earlier hold apart from the current one.
    private var holdGeneration = 0
    @Published var toast: String?
    @Published var appearance = UserDefaults.standard.string(forKey: "ui.appearance") ?? "system"
    @Published var onboarding: Bool
    /// 先体验 is running (`TryMode`).
    @Published var trying = false
    /// Ticks once a second while visible, for time-based display (the ambient view's clock).
    @Published var now = Date()

    private var timer: Timer?
    private var active = false

    /// UI refresh cadence for the device and tailnet rows while visible. Display only.
    static let refreshSeconds = 1.0

    init() {
        onboarding = !ChannelSettings.load().isComplete
        #if DEBUG
        if Demo.active {
            Demo.apply(self)
            return
        }
        #endif
        ConversationStore.shared.onChange = { [weak self] in
            Task { @MainActor in self?.chat = ConversationStore.shared.snapshot() }
        }
        AmbientController.shared.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let a = AmbientController.shared.snapshot()
                if a.isOn != self.ambient.isOn, !a.isOn { self.ambientExpanded = false }
                self.ambient = a
            }
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    func setAppearance(_ v: String) {
        appearance = v
        UserDefaults.standard.set(v, forKey: "ui.appearance")
    }

    func setActive(_ a: Bool) {
        active = a
        timer?.invalidate()
        timer = nil
        guard a else { return }
        #if DEBUG
        if Demo.active { return }
        #endif
        chat = ConversationStore.shared.snapshot()
        ambient = AmbientController.shared.snapshot()
        ConversationStore.shared.appBecameActive()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let d = PocketEngine.shared.snapshot()
        if d != device { device = d }
        now = Date()
        Task.detached {
            let st = Tailnet.shared.status()
            await MainActor.run { if self.tailnet != st { self.tailnet = st } }
        }
    }

    func save(_ s: ChannelSettings) {
        let roomChanged = s.host != settings.host || s.room != settings.room
        s.save()
        settings = s
        PocketEngine.shared.settingsChanged()
        ConversationStore.shared.settingsChanged()
        if roomChanged, ambient.isOn { AmbientController.shared.turnOff() }
    }

    // MARK: try-it mode

    func startTrying() {
        if ambient.isOn { AmbientController.shared.turnOff() }
        TryMode.enter()
        trying = true
        settings = ChannelSettings.load()
        onboarding = false
        PocketEngine.shared.settingsChanged()
        ConversationStore.shared.settingsChanged()
    }

    /// Drops everything the try-it room held and returns to the user's own connection, or to
    /// onboarding when there is none.
    func stopTrying() {
        if ambient.isOn { AmbientController.shared.turnOff() }
        quote = nil
        draftText = ""
        chips = []
        TryMode.exit()
        trying = false
        settings = ChannelSettings.load()
        onboarding = !settings.isComplete
        PocketEngine.shared.settingsChanged()
        ConversationStore.shared.settingsChanged()
    }

    // MARK: derived display state

    var voiceAvailable: Bool { chat.room?.cerebellumOK != false && chat.room?.uploadsDisabled != true }

    /// Nav subtitle, and the pose for the empty state and the ambient view (design §2 table).
    var presence: (pose: Pose, subtitle: String, live: Bool) {
        if !settings.isComplete { return (.offline, String(localized: "还没有设置"), false) }
        if chat.connection == .offline { return (.offline, String(localized: "连不上 · 正在重试"), false) }
        if holding { return (.heard, String(localized: "在听你说"), true) }
        if let w = chat.working {
            switch w.phase {
            case .received: return (.received, String(localized: "收到了"), true)
            case .thinking: return (.thinking, String(localized: "在想…"), true)
            // The phase only: the step line lives in the thread's working card (design §4.4). A
            // long subtitle widens the bar's centre item and pushes 多多 off centre.
            case .tool: return (.tool, String(localized: "在查"), true)
            case .streaming: return (.generating, String(localized: "正在回复"), true)
            }
        }
        if ambient.isOn {
            switch ambient.phase {
            case .muted: return (.muted, String(localized: "环境模式 · 已静音"), false)
            case .deaf, .seatTaken, .failed: return (.deaf, String(localized: "环境模式 · 听不到了"), false)
            case .interrupted: return (.sensesoff, String(localized: "环境模式 · 已暂停"), false)
            case .starting: return (.listening, String(localized: "环境模式 · 正在打开"), true)
            default:
                if ambient.speaking { return (.tts, String(localized: "环境模式 · 正在说"), true) }
                return (.listening, String(localized: "环境模式 · 在听"), true)
            }
        }
        if chat.connection == .connecting { return (.listening, String(localized: "连接中…"), false) }
        return (.listening, String(localized: "在线"), true)
    }

    // MARK: composer

    /// The text field is hidden in hold-to-talk mode, so its draft is neither counted nor sent.
    private var sendableText: String { voiceInput ? "" : draftText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSend: Bool {
        let hasText = !sendableText.isEmpty
        let uploaded = chips.allSatisfy { if case .uploaded = $0.state { true } else { false } }
        return (hasText || !chips.isEmpty) && uploaded
    }

    func send() {
        guard canSend else { return }
        let text = quote.map { UserQuote.compose(quote: $0, text: sendableText) } ?? sendableText
        let atts = chips.compactMap { if case .uploaded(let a) = $0.state { a } else { nil } }
        if !voiceInput { draftText = "" }
        quote = nil
        chips = []
        sentCount += 1
        Haptics.send()
        ConversationStore.shared.sendText(text, attachments: atts)
    }

    func addAttachment(name: String, mime: String, data: Data, thumbnail: UIImage?) {
        let chip = DraftChip(name: name, mime: mime, size: data.count, thumbnail: thumbnail, data: data)
        chips.append(chip)
        upload(chip.id)
    }

    func removeChip(_ id: UUID) { chips.removeAll { $0.id == id } }

    func upload(_ id: UUID) {
        guard let i = chips.firstIndex(where: { $0.id == id }) else { return }
        chips[i].state = .uploading
        let chip = chips[i]
        let client = ChannelClient(settings: settings, tuning: PocketTuning.load())
        let state = chat.room
        Task {
            let outcome = await client.upload(name: chip.name, mime: chip.mime, data: chip.data, state: state)
            guard let j = chips.firstIndex(where: { $0.id == id }) else { return }
            switch outcome {
            case .uploaded(let a): chips[j].state = .uploaded(a)
            case .tooLarge(let limit): chips[j].state = .failed(UploadPolicy.limitText(limit)); Haptics.warn()
            case .disabled: chips[j].state = .failed(String(localized: "频道没有开启上传")); Haptics.warn()
            case .failed(let why):
                AppLog.shared.log("upload_error", ["err": why])
                chips[j].state = .failed(String(localized: "上传失败 · 轻点重试"))
            }
        }
    }

    // MARK: hold-to-talk

    /// Starts a hold at touch-down. The recording sheet shows at once; the engine starts off the
    /// main thread, and once its input captures (`AVAudioEngine.start` returned, not the first
    /// 100 ms tap block) `holdLive` turns on, the timer starts and the start haptic fires: speech
    /// from then on is in the note.
    /// Synchronous, so the pressed button and the preparing sheet draw in the touch's own frame.
    func beginHold() -> Bool {
        HoldTiming.shared.mark("begin_hold")
        if VoiceIO.permission == .undetermined {
            // The permission alert takes the finger off the button: ask now, record next time.
            Task { if await VoiceIO.requestPermission() { toast = String(localized: "可以了，再按住说话") } }
            return false
        }
        guard VoiceIO.permission == .granted else {
            toast = String(localized: "需要麦克风权限才能说话")
            Haptics.warn()
            return false
        }
        Haptics.prepare()
        holdGeneration += 1
        let gen = holdGeneration
        holdStartedAt = Date()
        holdLive = false
        cancelArmed = false
        holding = true
        HoldTiming.shared.mark("holding")
        AmbientController.shared.pressBegan()
        VoiceIO.shared.startNote(live: { [weak self] in
            Task { @MainActor in self?.holdWentLive(gen) }
        }, failed: { [weak self] error in
            Task { @MainActor in self?.holdFailed(gen, error) }
        })
        return true
    }

    #if DEBUG
    /// Fixtures: show the live sheet without an engine.
    func demoLive() {
        holdLive = true
        holdStartedAt = Date().addingTimeInterval(-3)
    }
    #endif

    private func holdWentLive(_ gen: Int) {
        guard holding, gen == holdGeneration, !holdLive else { return }
        HoldTiming.shared.mark("live")
        holdStartedAt = Date()
        // The start haptic fires where the sheet switches to live (`HoldOverlay`), so feel and
        // picture change in the same frame.
        holdLive = true
    }

    private func holdFailed(_ gen: Int, _ error: Error) {
        AppLog.shared.log("hold_error", ["err": "\(error)"])
        guard holding, gen == holdGeneration else { return }
        holding = false
        holdLive = false
        cancelArmed = false
        HoldTiming.shared.end("engine_error")
        AmbientController.shared.pressEnded()
        toast = String(localized: "麦克风打不开")
        Haptics.warn()
    }

    /// A release before this is a tap, not speech (decision Q4, design §4.6): the same threshold
    /// the Passport firmware applies to its button.
    static let holdMinimum: TimeInterval = 0.3

    func endHold(send: Bool, heldFor: TimeInterval) {
        guard holding else { HoldTiming.shared.end("not_started"); return }
        let wasLive = holdLive
        holding = false
        holdLive = false
        // Released before the input started: nothing was recorded, which reads as a tap too.
        let tooShort = heldFor < Self.holdMinimum || !wasLive
        HoldTiming.shared.end(send ? (tooShort ? "too_short" : "send") : "cancel")
        AmbientController.shared.pressEnded()
        let keep = send && !tooShort
        // Release feedback is immediate; the packets arrive once the capture has stopped.
        if keep { Haptics.send(); sentCount += 1 } else { Haptics.cancel() }
        if tooShort { toast = String(localized: "按住说话") }
        VoiceIO.shared.stopNote(keep: keep) { packets in
            guard keep, !packets.isEmpty else { return }
            Task { @MainActor in ConversationStore.shared.sendVoice(packets) }
        }
    }

    // MARK: ambient

    func toggleAmbient() {
        if ambient.isOn {
            AmbientController.shared.turnOff()
            return
        }
        Task {
            guard await VoiceIO.requestPermission() else {
                toast = String(localized: "需要麦克风权限才能听")
                return
            }
            AmbientController.shared.turnOn()
            ambientExpanded = true
        }
    }
}

/// Mic level for meters, sampled by views only while they are visible.
func meterLevel() -> Float {
    #if DEBUG
    if Demo.active { return Demo.level(Date()) }
    #endif
    return VoiceIO.shared.level
}
