// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

#if DEBUG
import Foundation
import PocketCore
import PocketOpus
import SwiftUI

/// Debug-only fixtures and probes, selected by launch arguments:
///
/// - `-PocketDemo <screen>`: shows one design state (the mockup names of design §4, the cases
///   in `apply`) with fixed content and no channel. Stored settings and the cache are untouched.
/// - `-PocketAmbientProbe <seconds>`: turns ambient on muted for that long, to check the edge
///   handshake in the log against a real channel.
/// - `-PocketPlaybackProbe <seconds>`: plays a test tone of that length through the ambient
///   playback path, no socket; logs `playback_probe`.
/// - `-PocketHoldProbe <count>`: presses and cancels hold-to-talk that many times without a
///   finger; each press logs `hold_timing`.
/// - `-PocketHoldProbeAmbientEngine YES`: with `-PocketHoldProbe`, runs the ambient engine
///   first, to time a press while ambient is on.
enum Demo {
    /// English fixture content when the app runs in English, so English renders show English.
    static var en: Bool { PocketEngine.uiLanguage == .en }
    static func L(_ zh: String, _ en: String) -> String { Self.en ? en : zh }
    static let screen: String? = UserDefaults.standard.string(forKey: "PocketDemo")
    static var active: Bool { screen != nil }

    /// `-PocketAmbientProbe <seconds>`: turns ambient on muted (no audio leaves the phone), so
    /// the edge handshake can be checked in the log against a real channel, then turns it off.
    static func runAmbientProbe() {
        let secs = UserDefaults.standard.double(forKey: "PocketAmbientProbe")
        guard secs > 0 else { return }
        AppLog.shared.log("ambient_probe", ["seconds": secs])
        AmbientController.shared.setMuted(true)
        AmbientController.shared.turnOn()
        AmbientController.shared.setMuted(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { AmbientController.shared.turnOff() }
    }

    /// `-PocketPlaybackProbe <seconds>`: starts the ambient engine (no socket), plays an encoded and
    /// decoded test tone of that length through the playback path, and logs `playback_probe` with
    /// how many blocks were decoded, scheduled and reported played back.
    static func runPlaybackProbe() {
        let secs = UserDefaults.standard.double(forKey: "PocketPlaybackProbe")
        guard secs > 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            AppLog.shared.log("playback_probe_start", ["seconds": secs])
            do {
                try VoiceIO.shared.startAmbient { _ in }
            } catch {
                AppLog.shared.log("playback_probe", ["err": "\(error)"])
                return
            }
            // Probe only: schedule after the configuration change that follows a voice-processing
            // start, which is the state a live speech meets.
            Thread.sleep(forTimeInterval: 1)
            let rate = Double(PocketConstants.sampleRate)
            let tone = (0..<Int(secs * rate)).map { Int16(3000 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
            var decoded = 0, scheduled = 0
            let played = Counter()
            if let enc = try? OpusVoiceEncoder(), let dec = try? OpusVoiceDecoder(), let packets = try? enc.push(tone) {
                for p in packets {
                    guard let s = try? dec.decode(p), !s.isEmpty else { continue }
                    decoded += 1
                    if VoiceIO.shared.schedule(s, done: { played.add() }) { scheduled += 1 }
                }
            }
            Thread.sleep(forTimeInterval: secs + 2)
            AppLog.shared.log("playback_probe", ["decoded": decoded, "scheduled": scheduled, "played": played.value,
                                                 "running": VoiceIO.shared.running, "route": VoiceIO.routeName])
            VoiceIO.shared.stopAmbient()
        }
    }

    /// `-PocketHoldProbe <count>`: presses 按住说话 that many times without a finger, through the
    /// same `beginHold` / `endHold` the gesture calls, and cancels each one, so nothing is sent.
    /// Each press logs `hold_timing`; the touch-to-handler delay of a real finger is not covered.
    /// Probe pacing only: one second held (long enough for the waveform to move), one second idle.
    @MainActor
    static func runHoldProbe(_ model: AppModel) {
        let count = UserDefaults.standard.integer(forKey: "PocketHoldProbe")
        guard count > 0 else { return }
        let ambientEngine = UserDefaults.standard.bool(forKey: "PocketHoldProbeAmbientEngine")
        AppLog.shared.log("hold_probe", ["count": count, "ambient_engine": ambientEngine])
        Task { @MainActor in
            if ambientEngine { try? VoiceIO.shared.startAmbient { _ in } }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for _ in 0..<count {
                HoldTiming.shared.begin(eventAge: 0)
                let ok = model.beginHold()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if ok { model.endHold(send: false, heldFor: 1) } else { HoldTiming.shared.end("begin_failed") }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if ambientEngine { VoiceIO.shared.stopAmbient() }
            AppLog.shared.log("hold_probe_done")
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A moving level for meters and the waveform in screenshots.
    static func level(_ t: Date) -> Float {
        let x = t.timeIntervalSinceReferenceDate
        return Float(0.35 + 0.3 * sin(x * 7) * sin(x * 2.3) + 0.15 * sin(x * 13))
    }

    private static func at(_ daysAgo: Int, _ h: Int, _ m: Int) -> String {
        var c = Calendar.current
        c.timeZone = .current
        let day = c.date(byAdding: .day, value: -daysAgo, to: Date())!
        let d = c.date(bySettingHour: h, minute: m, second: 0, of: day)!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private static var history: [ImlogEntry] {
        [
            ImlogEntry(at: at(1, 22, 40), kind: "typed", text: L("明早八点叫我，要去机场", "Wake me at eight tomorrow, I'm flying out"), utt_id: "d1"),
            ImlogEntry(at: at(1, 22, 40), speaker: "多多", kind: "answer", text: L("好，明早 8:00 叫你。去首都机场的话，七点半前出门比较稳。", "OK, I'll wake you at 8:00. For the airport, leaving before 7:30 is safest."), unspoken: true),
            ImlogEntry(at: at(0, 8, 12), kind: "typed", text: L("早上好，帮我看下今天要带伞吗", "Morning. Do I need an umbrella today?"), utt_id: "d2"),
            ImlogEntry(at: at(0, 8, 12), speaker: "多多", kind: "answer", text: L("要带。北京今天下午两点后有阵雨，降水概率 70%，傍晚停。", "Yes. Showers after 2 pm, 70% chance, clearing by evening."), unspoken: true),
        ]
    }

    private static var passportAsk: ImlogEntry {
        ImlogEntry(at: at(0, 9, 38), kind: "typed", text: L("明天下午三点提醒我给妈妈打电话，顺便看看那个时间我有没有别的安排", "Remind me to call Mom at 3 pm tomorrow, and check if I'm free then"),
                   utt_id: "d3", voice_source: "passport")
    }

    @MainActor
    static func apply(_ m: AppModel) {
        guard let screen else { return }
        // Placeholder channel settings for this launch only (the argument domain is not saved),
        // so no stored host or room shows in a fixture.
        let d = UserDefaults.standard
        var args = d.volatileDomain(forName: UserDefaults.argumentDomain)
        args["channel.host"] = "your-host.tailnet.ts.net"
        args["channel.room"] = "study"
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        m.settings = ChannelSettings.load()
        m.persistComposerMode = false
        m.voiceInput = !["composer-text", "attachments"].contains(screen)
        m.onboarding = screen.hasPrefix("onboard")
        m.device.link = .ready
        m.device.deviceName = "DuoDuo Pocket 3F2A"
        m.device.battery = 82
        m.device.charging = .unknown
        m.device.info = DeviceInfo(protoMajor: 1, protoMinor: 1, firmware: "1.0.3", battery: 82, charging: .unknown, preroll: true)
        m.device.lastPressAt = Date()
        m.device.lastReply = L("好，明天 15:00 提醒你给妈妈打电话。那个时间你没有别的安排。", "OK, I'll remind you to call Mom at 15:00 tomorrow. You're free then.")
        m.tailnet = TailnetStatus(backend_state: "Running", auth_url: nil, ips: ["100.64.0.12"], dns_name: nil, error: nil)
        var chat = ChatSnapshot()
        chat.configured = true
        chat.connection = .online
        chat.room = RoomState(room: "study", roomName: L("书房", "Study"), date: "", daemonOK: true, cerebellumOK: true)
        chat.hasHistory = true
        var entries = history
        var turn = TurnState()
        var outbox: [OutboxItem] = []
        var durations = ["d3": 6000, "d5": 5000]
        var notes: [(at: Date, text: String)] = []
        switch screen {
        case "empty":
            entries = []
            chat.hasHistory = false
            m.device.link = .scanning
            m.device.deviceName = nil
        case "chat-working", "passport-sheet", "settings":
            entries.append(passportAsk)
            turn.expect(uttID: "d3")
            feedTools(&turn, Self.toolRun, finishLast: false)
        case "chat-done", "chat-done-tap":
            entries.append(passportAsk)
            let start = Date().addingTimeInterval(-40)
            turn.expect(uttID: "d3", now: start)
            feedTools(&turn, Self.toolRun, finishLast: true)
            let answer = L("好，明天 15:00 提醒你给妈妈打电话。那个时间你没有别的安排，日历上 14:00–17:00 是空的。", "OK, I'll remind you to call Mom at 15:00 tomorrow. You're free: your calendar is clear from 14:00 to 17:00.")
            turn.handle(frame: ["type": "answer_final", "utt_id": "d3", "text": answer], now: start.addingTimeInterval(23))
            let row = ImlogEntry(at: at(0, 9, 39), speaker: "多多", kind: "answer", text: answer, unspoken: true)
            turn.settle(with: [row])
            entries.append(row)
        case "voice-states":
            entries = [ImlogEntry(at: at(0, 9, 54), kind: "typed", text: L("下午的会几点开始", "What time is the afternoon meeting?"), utt_id: "v0"),
                       ImlogEntry(at: at(0, 9, 55), speaker: "多多", kind: "answer", text: L("两点半，在 3 号会议室，你之前标了要带上季度的数据。", "2:30 in room 3. You noted to bring last quarter's numbers."), unspoken: true),
                       ImlogEntry(at: at(0, 10, 4), kind: "typed", text: L("周五晚上那家日料店还能订吗，四个人", "Can we still book that sushi place for four on Friday night?"), utt_id: "d5", voice_source: "phone")]
            outbox = [OutboxItem(body: .voice(voiceID: UUID(), durationMs: 4000), state: .failed(reason: String(localized: "没发出去 · 轻点重试")))]
            notes = [(ThreadBuilder.parse(at(0, 10, 2))!, String(localized: "没听清，再说一次"))]
            outbox.append(OutboxItem(body: .voice(voiceID: UUID(), durationMs: 5000), state: .sending))
            turn.expect(uttID: "d5")
            turn.handle(frame: ["type": "duoduo_said", "speech_id": "c-d5", "text": L("我查了一下，周五 19:00 和 20:30 还有四人位。要我帮你订下来，晚点提醒你打电话吗", "I checked: tables for four are free at 19:00 and 20:30 on Friday. Want me to remind you to call and book")])
        case "composer-voice", "composer-text":
            entries.append(passportAsk)
            entries.append(ImlogEntry(at: at(0, 9, 39), speaker: "多多", kind: "answer", text: L("好，明天 15:00 提醒你给妈妈打电话。那个时间你没有别的安排。", "OK, I'll remind you to call Mom at 15:00 tomorrow. You're free then."), unspoken: true))
            if screen == "composer-text" { m.draftText = L("晚上的会改到八点了", "Tonight's meeting moved to eight") }
        case "duoduo-files":
            // A row as the channel writes it for files 多多 sent. The image's sha256 names no real
            // attachment, so the row shows its placeholder; the PDF is a card with no bytes.
            entries.append(ImlogEntry(at: at(0, 10, 30), kind: "typed", text: L("把刚才那张照片和行程单发我", "Send me that photo and the itinerary"), utt_id: "f1"))
            entries.append(ImlogEntry(at: at(0, 10, 30), speaker: "多多", kind: "answer", text: L("发了，照片和明天的行程单。", "Sent: the photo and tomorrow's itinerary."), unspoken: true))
            entries.append(ImlogEntry(at: at(0, 10, 31), speaker: "多多", kind: "answer", text: "", attachments: [
                ChannelAttachment(name: L("照片.jpg", "photo.jpg"), mime: "image/jpeg", sha256: "00"),
                ChannelAttachment(name: L("明天行程.pdf", "itinerary.pdf"), mime: "application/pdf"),
            ]))
        case "hold-record", "hold-cancel", "hold-preparing":
            entries.append(passportAsk)
            entries.append(ImlogEntry(at: at(0, 9, 39), speaker: "多多", kind: "answer", text: L("好，明天 15:00 提醒你给妈妈打电话。那个时间你没有别的安排。", "OK, I'll remind you to call Mom at 15:00 tomorrow. You're free then."), unspoken: true))
            m.holding = true
            m.cancelArmed = screen == "hold-cancel"
            if screen != "hold-preparing" { m.demoLive() }
        case "attachments":
            entries = [ImlogEntry(at: at(1, 21, 14), kind: "typed", text: L("这是上周去爬的山，帮我认一下是哪座", "This is the hill I climbed last week. Which one is it?"), utt_id: "a1",
                                  attachments: [ChannelAttachment(name: L("山.jpg", "hill.jpg"), mime: "image/jpeg")]),
                       ImlogEntry(at: at(1, 21, 15), speaker: "多多", kind: "answer", text: L("看山脊线和远处的电视塔，应该是香山，从北门上的那条路。", "From the ridge line and the TV tower, it's Fragrant Hills, the trail from the north gate."), unspoken: true),
                       ImlogEntry(at: at(0, 10, 20), kind: "typed", text: L("跟上一版比，贵在哪", "What costs more than in the last version?"), utt_id: "a2",
                                  attachments: [ChannelAttachment(name: L("装修报价-v2.pdf", "renovation-quote-v2.pdf"), mime: "application/pdf", sha256: "00")])]
            m.draftText = L("这两张是现场照片", "Two photos from the site")
            m.chips = [DraftChip(name: "IMG_1.jpg", mime: "image/jpeg", size: 1, thumbnail: swatch(.systemTeal), data: Data(),
                                 state: .uploaded(ChannelAttachment(name: "a", mime: "image/jpeg"))),
                       DraftChip(name: "IMG_2.jpg", mime: "image/jpeg", size: 1, thumbnail: swatch(.systemGreen), data: Data()),
                       DraftChip(name: L("报价.pdf", "quote.pdf"), mime: "application/pdf", size: 1, thumbnail: nil, data: Data(),
                                 state: .failed(UploadPolicy.limitText(10 * 1_048_576)))]
        case "ambient-call", "ambient-chat":
            entries.append(ImlogEntry(at: at(0, 18, 30), kind: "typed", text: L("今晚吃什么好", "What should we have for dinner?"), utt_id: "b1"))
            entries.append(ImlogEntry(at: at(0, 18, 31), speaker: "多多", kind: "answer", text: L("冰箱里还有上周买的牛腩和土豆，可以做个土豆炖牛腩，一个小时左右。", "There's beef and potatoes in the fridge from last week. A beef and potato stew takes about an hour.")))
            for (i, l) in [("V1", L("多多，帮我想想周末带孩子去哪", "DuoDuo, where should we take the kids this weekend?")), ("V2", L("别太远，开车一小时以内", "Not too far, under an hour's drive")), ("V1", L("最好有草坪", "Somewhere with grass")), ("V2", L("带上野餐垫", "Bring the picnic blanket")), ("V1", L("那就这么定", "Let's do that"))].enumerated() {
                entries.append(ImlogEntry(at: at(0, 19, 2 + i), speaker: l.0, kind: "human", text: l.1))
            }
            turn.handle(frame: ["type": "duoduo_said", "speech_id": "c-x", "text": L("一小时车程内有三个适合孩子的：奥森的儿童乐园、温榆河公园的草坪，还有北京植物园…", "Three kid-friendly spots within an hour: the Olympic Forest Park playground, the Wenyu River Park lawns, and the Botanical Garden…")])
            chat.lastHeard = L("V1  多多，帮我想想周末带孩子去哪", "V1  DuoDuo, where should we take the kids this weekend?")
            m.ambient = AmbientSnapshot(phase: .listening, speaking: true, speakingFiller: false, aec: true, route: String(localized: "扬声器"))
            m.ambientExpanded = screen == "ambient-call"
        case "ambient-tool":
            // A long shell command with a description, ambient open.
            entries.append(ImlogEntry(at: at(0, 23, 14), speaker: "V?", kind: "human", text: L("帮我看看电脑硬盘还剩多少空间。", "How much disk space is left on my computer?")))
            turn.handle(frame: ["type": "turn", "phase": "thinking"])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Bash"])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Bash", "input_summary":
                #"{"command":"df -h / /System/Volumes/Data 2>/dev/null | awk '{print $1, $2, $3, $4, $5, $9}'","description":"Show disk space on the root and data volumes, including the snapshot reserve and purgeable space"}"#])
            chat.lastHeard = L("V?: 帮我看看电脑硬盘还剩多少空间。", "V?: How much disk space is left on my computer?")
            m.ambient = AmbientSnapshot(phase: .listening, speaking: false, speakingFiller: false, aec: true, route: String(localized: "扬声器"))
            m.ambientExpanded = true
        case "passport-pair":
            m.device.link = .pairing
        case "offline":
            entries = [passportAsk, ImlogEntry(at: at(0, 9, 39), speaker: "多多", kind: "answer", text: L("好，明天 15:00 提醒你给妈妈打电话。那个时间你没有别的安排。", "OK, I'll remind you to call Mom at 15:00 tomorrow. You're free then."), unspoken: true)]
            chat.connection = .offline
            chat.cachedAt = ThreadBuilder.parse(at(0, 9, 40))
            outbox = [OutboxItem(body: .text(L("晚上的会改到八点了", "Tonight's meeting moved to eight"), attachments: []))]
        case "onboard-tailnet":
            m.tailnet = TailnetStatus(backend_state: "NeedsLogin", auth_url: "https://login.tailscale.com/a/demo", ips: nil, dns_name: nil, error: nil)
        case "onboard-connect":
            break  // Tailscale is Running, so onboarding opens at step 2; see `connectionCheck`.
        case "live-long-answer":
            playLongAnswer(m, chat: chat)
            return
        default:
            break
        }
        durations["d3"] = 6000
        chat.rows = ThreadBuilder().build(.init(entries: entries, outbox: outbox, turn: turn, durations: durations, notes: notes))
        chat.working = turn.working
        m.chat = chat
    }

    /// A scrolled thread; a tool turn whose answer is shown live but never logged (the channel
    /// skipped it as superseded); a later note; a long answer to it; one more short exchange.
    /// Frames and log rows come in the order the channel sends them, and each step rebuilds the
    /// rows as ConversationStore does.
    /// Steps: 0 s working · 1 s unlogged answer · 2 s next note · 4 s its long `answer_final` ·
    /// 4.2 s its log row · 6 s next note · 6.5 s its short answer.
    @MainActor
    private static func playLongAnswer(_ m: AppModel, chat: ChatSnapshot) {
        var entries: [ImlogEntry] = []
        for i in 0..<14 {
            entries.append(ImlogEntry(at: at(0, 8, 2 * i), kind: "typed", text: L("第 \(i + 1) 个问题：今天的安排里有什么要提前准备的", "Question \(i + 1): anything to prepare for today?"), utt_id: "h\(i)",
                                      voice_source: i % 2 == 0 ? "passport" : nil))
            entries.append(ImlogEntry(at: at(0, 8, 2 * i + 1), speaker: "多多", kind: "answer",
                                      text: L("第 \(i + 1) 个回答：上午十点的评审会要带上季度数据，下午三点前把报价单发给对方。", "Answer \(i + 1): bring last quarter's numbers to the 10:00 review, and send the quote before 3 pm."), unspoken: true))
        }
        entries.append(ImlogEntry(at: at(0, 9, 30), kind: "typed", text: L("帮我把这周的菜单排一下，顺便列个采购清单", "Plan this week's dinners and make a shopping list"), utt_id: "L0",
                                  voice_source: "passport"))
        let paragraph = L("周一番茄炒蛋配米饭，周二土豆炖牛腩，周三清蒸鱼和炒青菜，周四咖喱鸡，周五在外面吃。"
            + "采购清单：番茄六个、鸡蛋一盒、牛腩一斤、土豆四个、鲈鱼一条、青菜两把、鸡腿四只、咖喱块一盒。",
            "Monday tomato and egg with rice, Tuesday beef stew, Wednesday steamed fish and greens, Thursday curry chicken, "
            + "Friday eat out. Shopping list: six tomatoes, a dozen eggs, a pound of beef, four potatoes, one sea bass, "
            + "two bunches of greens, four chicken legs, a box of curry.")
        let medium = (0..<3).map { L("第 \($0 + 1) 段。", "Part \($0 + 1). ") + paragraph }.joined(separator: "\n\n")
        let long = (0..<9).map { L("第 \($0 + 1) 段。", "Part \($0 + 1). ") + paragraph }.joined(separator: "\n\n")
        var turn = TurnState()
        turn.expect(uttID: "L0")
        feedTools(&turn, Self.toolRun, finishLast: false)
        var chat = chat
        func show() {
            chat.rows = ThreadBuilder().build(.init(entries: entries, turn: turn))
            chat.working = turn.working
            m.chat = chat
        }
        show()
        func later(_ s: Double, _ f: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func now() -> String { iso.string(from: Date()) }
        later(1) {
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Notify ✓"])
            turn.handle(frame: ["type": "answer_final", "utt_id": "L0", "text": medium, "speech_id": "ch:L0"])
            turn.handle(frame: ["type": "turn", "utt_id": "L0", "phase": "idle"])
            show()
        }
        later(2) {
            entries.append(ImlogEntry(at: now(), kind: "typed", text: L("周三换成排骨吧，鱼放到周末", "Make Wednesday ribs, move the fish to the weekend"), utt_id: "L1", voice_source: "passport"))
            turn.expect(uttID: "L1")
            turn.handle(frame: ["type": "turn", "phase": "thinking"])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Bash", "input_summary": #"{"command":"cat ~/Documents/menu.md","description":"Read the saved menu"}"#])
            show()
        }
        later(4) {
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": "Bash ✓"])
            turn.handle(frame: ["type": "answer_final", "utt_id": "L1", "text": long, "speech_id": "ch:L1"])
            show()
        }
        later(4.2) {
            let row = ImlogEntry(at: now(), speaker: "多多", kind: "answer", text: long, utt_id: "L1", unspoken: true)
            entries.append(row)
            turn.settle(with: [row])
            show()
        }
        later(6) {
            entries.append(ImlogEntry(at: now(), kind: "typed", text: L("好的，知道了", "OK, got it"), utt_id: "L2", voice_source: "phone"))
            turn.expect(uttID: "L2")
            show()
        }
        later(6.5) {
            let a = ImlogEntry(at: now(), speaker: "多多", kind: "answer", text: L("嗯，随时喊我。", "Sure, call me anytime."), utt_id: "L2", unspoken: true)
            turn.handle(frame: ["type": "answer_final", "utt_id": "L2", "text": a.text])
            entries.append(a)
            turn.settle(with: [a])
            show()
        }
    }

    /// A turn as the channel reports it (tool name, raw JSON input), from the field screenshot
    /// with the personal content replaced.
    private static var toolRun: [(String, String)] { en ? toolRunEN : toolRunZH }

    private static let toolRunEN: [(String, String)] = [
        ("Bash", #"{"command":"duoduo channel list 2>&1 | head -40; echo =====; duoduo channel status 2>&1 | head -20"}"#),
        ("Bash", #"{"command":"cat ~/notes/connections.md | tail -60","description":"Read the connection notes"}"#),
        ("mcp__duoduo__calendar_query", #"{"query":"tomorrow 14:00–17:00","calendar":"personal"}"#),
        ("Read", #"{"file_path":"~/Documents/family/phone-reminders.md","limit":40}"#),
        ("Grep", #"{"pattern":"Mom|call","path":"~/Documents"}"#),
        ("mcp__duoduo__reminder_create", #"{"title":"Call Mom","due":"2026-10-08T15:00:00+08:00"}"#),
        ("Notify", #"{"notify_content":"Reminder at 15:00 tomorrow: call Mom\n(from the Pocket session)"}"#),
    ]

    private static let toolRunZH: [(String, String)] = [
        ("Bash", #"{"command":"duoduo channel list 2>&1 | head -40; echo =====; duoduo channel status 2>&1 | head -20"}"#),
        ("Bash", #"{"command":"cat ~/notes/connections.md | tail -60","description":"Read the connection notes"}"#),
        ("mcp__duoduo__calendar_query", #"{"query":"明天 14:00–17:00","calendar":"personal"}"#),
        ("Read", #"{"file_path":"~/Documents/family/phone-reminders.md","limit":40}"#),
        ("Grep", #"{"pattern":"妈妈|电话","path":"~/Documents"}"#),
        ("mcp__duoduo__reminder_create", #"{"title":"给妈妈打电话","due":"2026-10-08T15:00:00+08:00"}"#),
        ("Notify", #"{"notify_content":"明天 15:00 提醒：给妈妈打电话\n（来自随身会话）"}"#),
    ]

    /// Early frame, full call and result per tool, as the channel sends them.
    private static func feedTools(_ turn: inout TurnState, _ run: [(String, String)], finishLast: Bool) {
        for (i, (name, input)) in run.enumerated() {
            turn.handle(frame: ["type": "turn", "phase": "thinking"])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": name])
            turn.handle(frame: ["type": "turn", "phase": "tool", "label": name, "input_summary": input])
            if finishLast || i < run.count - 1 {
                turn.handle(frame: ["type": "turn", "phase": "tool", "label": name + " ✓"])
            }
        }
    }

    @MainActor
    static var sheet: ConversationView.Sheet? {
        switch screen {
        case "passport-sheet", "passport-pair": .passport
        case "settings": .settings
        default: nil
        }
    }

    private static func swatch(_ c: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            c.withAlphaComponent(0.6).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.white.withAlphaComponent(0.8).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 36, y: 10, width: 16, height: 16))
        }
    }
}
extension ConnectionCheck {
    /// The passed checklist for fixtures, instead of a live check against the placeholder host.
    func showDemoPass() {
        items = [.init(id: 0, text: String(localized: "Tailscale 已连接"), state: .ok),
                 .init(id: 1, text: String(localized: "频道可达 · \(38) ms"), state: .ok),
                 .init(id: 2, text: String(localized: "房间「\(Demo.L("书房", "Study"))」存在") + String(localized: "，多多在线"), state: .ok)]
    }
}
#endif
