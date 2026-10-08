# 多多随身 — native app design

Status: implemented in `App/`. The native SwiftUI product UI replaced an earlier web-view shell.
The contracts it builds on are the ambient wire protocol (`@openduo/ambient-protocol`), the
channel HTTP/WS API (`channel-ambient/src/server/http.ts`) and the Passport link
(`docs/ble-protocol.md`). Screens: the `-PocketDemo` fixtures (section 11).

## 1. Product in one paragraph

One app is one room. It reads like a chat with one person, 多多, plus a voice call. The user types,
holds the mic to send a voice note, attaches photos and files, or turns on ambient mode, in which the
phone listens to the room and speaks 多多's answers. The Passport is an accessory of this app: a
pocket push-to-talk whose voice notes and replies appear in the same conversation. The server is the
authority for history; the app caches it for offline reading.

## 2. Visual language

duoduo identity, iOS conventions. Values come from the ambient tokens
(`channel-ambient/web/tokens/colors.css`, `theme-light.css`).

| Role | Light ("paper") | Dark ("warm black") | Note |
|---|---|---|---|
| Background | `#f5f4ed` | `#0e0e0d` | warm, never pure white / black |
| Grouped background / cell | `#efeee6` / `#faf9f5` | `#0b0b0a` / `#171716` | Settings, sheets |
| Brand (tint, buttons, live state) | `#1a7175` ink-teal | `#1fd9de` electric teal | one accent only |
| On-brand text | `#faf9f5` | `#0a1414` | |
| My bubble | fill `#1a7175`, text `#faf9f5` | fill `#12484b`, text `#effcfc` | dark fill is teal sunk into black; a full `#1fd9de` flood per message is too loud and the token rule says brand is a signal |
| 多多's bubble | `#e9e8df`, text `#141413` | `#1f1f1d`, text `#dddcd5` | |
| Text ramp | `#141413` / `#60605d` / `#80807c` / `#abaaa5` | `#f5f4ed` / `#b4b3ac` / `#8d8c86` / `#5c5b57` | primary / secondary / tertiary / placeholder |
| Hairline | `#dad9d3` | `#282826` | 0.5 pt separators |
| OK (connected) | `#0e9f6e` | `#4ac994` | always paired with a word |
| Attention (failed, offline) | `#7a3e00` on `#ece2cc` | `#d9a066` on `#2a2015` | brown, not red: colour-blind safe against OK |
| Destructive (forget device, end) | system red | system red | iOS convention |

- Type: SF Pro + PingFang SC (system font), Dynamic Type text styles. Bubble text `.body` (17 pt).
- Shapes: bubbles 19 pt continuous corners with a 6 pt tail corner; buttons are circles or 14 pt
  rounded rectangles. The web system is square (radius 0); this deviation is open question Q1.
- Avatar: the duoduo dog poses (`channel-ambient/web/avatar/*-{paper,dark}.svg`), shipped as asset
  catalog vectors. The dog appears only where it is the content: the empty state, onboarding, and
  the ambient view (rings animate with listening and speaking). The nav bar carries 多多's live
  state as text (the subtitle); a decorative avatar there cost 12 pt of height and said nothing the
  subtitle does not. No avatars beside bubbles. Pose and subtitle per state:

| State | Pose | Nav subtitle |
|---|---|---|
| online, idle | `listening` | 在线 |
| voice note uploading / ambient hears speech | `heard` | 在听你说 |
| `turn received` | `received` | 收到了 |
| `turn thinking` | `thinking` | 在想… |
| `turn tool` | `tool` | 在查 (the step line stays in the working card, §4.4) |
| `duoduo_said` streaming | `generating` | 正在回复 |
| playback (ambient) | `tts` | 正在说 |
| ambient muted | `muted` | 环境模式 · 已静音 |
| ambient seat `unowned` / mic revoked | `deaf` | 听不到了 |
| offline / connecting | `offline` | 连不上 · 正在重试 |

- Motion: pose cross-fade 200 ms (empty state, ambient view); thinking dots pulse; level meter follows mic RMS. Reduce Motion
  replaces all of it with static poses and text.
- Haptics: recording started (light impact, when the microphone input starts capturing, not at
  the touch),
  the finger crossing the hold button's edge either way (selection), send (notification
  success), cancel or too short (rigid impact), failure (notification warning). The audio
  session allows haptics while recording; without that iOS drops every haptic during a hold.

## 3. Information architecture

```
App
├── Onboarding (first run, or settings incomplete)
│   ├── 1 Tailscale login
│   ├── 2 Channel host + room, connection check
│   └── 3 Add Passport (optional, skippable)
└── Conversation (the only root screen)
    ├── Nav bar (standard inline, 44 pt): settings · 多多 + live-state subtitle · Passport chip · ambient button
    ├── Banner slot: offline / tailnet login / server problem / ambient pill
    ├── Thread (server history + local pending rows)
    ├── Composer: mode toggle · 按住说话 bar or text field · + · send
    ├── Hold-to-talk overlay
    ├── Ambient view (full screen, "call") ⇄ ambient pill (minimised)
    ├── Attachment menu → Photos picker / Camera / Files
    ├── Passport sheet (status, latest reply, re-pair, logs, forget)
    │   └── Pairing sheet
    └── Settings sheet
        ├── Connection (host, port, HTTPS, room) · Tailscale (state, log out)
        ├── Sound (ambient output route, keep listening in background*, haptics, microphone when AirPods are connected)
        ├── Passport → Passport sheet
        ├── Appearance (system / light / dark)
        └── Diagnostics (export logs, about)
```

`*` exists only if Q3 is decided for background ambient.

No room switching, no room list, no room preview. The room is a setting.

## 4. Screens and states

### 4.1 Onboarding

| Step | Content | Exit |
|---|---|---|
| 1 Tailscale | Dog (`offline` pose), "先连上你的网络", one line on why, node name `duoduo-pocket`. Button 登录 Tailscale opens `auth_url` from `TsbridgeStatus` in `ASWebAuthenticationSession`. While waiting: "已在浏览器打开登录页，完成后回到这里", polling `backend_state`. | `backend_state == Running` |
| 2 Find 多多 | Host, room; port + HTTPS collapsed under one row. Live checklist: Tailscale connected → `GET /healthz` 200 (latency shown) → `GET /api/state?room=` 200, `daemon_ok`, `cerebellum_ok`. A 400 with `rooms` offers the room names as suggestions. | all three checks pass; 稍后再说 allowed |
| 3 Passport | Same as the pairing sheet (4.9). Skippable. | paired or skipped |

Permissions are requested in context, not up front: microphone on first hold or first ambient on;
Bluetooth on step 3 or the first Passport action; Photos/Camera on first use.

### 4.2 Conversation states

| State | Trigger | What the user sees |
|---|---|---|
| Empty | connected, history empty | Dog `listening`, "我在，随时说", three cards: hold to talk, ambient mode, add Passport (screens `empty`) |
| Connecting | launch, foreground, settings change | Cached thread at once; nav subtitle 连接中…; no banner for the first 2 s (Q9) |
| Connected | display socket open and `/api/state` 200 | Nav subtitle 在线 |
| Offline | socket cannot be restored, request fails | Attention banner "连不上多多 · 显示 HH:MM 缓存的记录" + 重试; nav subtitle 连不上 · 正在重试; sends are queued (Q5) (screens `offline`) |
| Tailnet login needed | `backend_state == NeedsLogin` | Banner "需要重新登录 Tailscale" + 登录; nothing else changes |
| 多多 cannot reply | `/api/state.daemon_ok == false` | Banner "多多暂时无法回复，消息会先记下"; sending still allowed |
| Voice unavailable | `cerebellum_ok == false` or `cerebellum` frame `ok:false` | Mic and ambient button dimmed; tap explains "语音服务暂不可用"; typing still works |
| Config issue | `/api/state.config_issues` non-empty | Diagnostics row in Settings only; not a user banner |

### 4.3 Thread rows

Built from `imlog` entries (server authority) plus local rows that have not yet appeared there.

| Entry | Row |
|---|---|
| `kind: "typed"`, no `voice_source` | my text bubble (+ attachments above it) |
| `kind: "typed"`, `voice_source: "phone"` | my voice bubble: head "语音 · 0:06", transcript as text |
| `kind: "typed"`, `voice_source: "passport"` | my voice bubble with Passport glyph |
| `kind: "answer"` / speaker `多多` | 多多's bubble; spoken rows get "已播报", `truncated` gets "只播了一部分", `unspoken` gets nothing |
| speaker `多多`, empty `text`, `attachments` | files 多多 sent (outbox `payload.attachments`, filed by the channel): images inline, files as cards, no spoken meta; never a Passport reply |
| `kind: "reaction"` | not shown in the thread (fillers like 「我看看」) |
| `kind: "human"` (ambient room speech) | compact "heard" row: speaker chip `V1` + text, not a bubble; runs of more than 3 fold into "房间里还说了 N 句" (Q6) |
| `understood addressed:false` / `wake_ignored` / `ack_silenced` | folded note "听到了，不是在叫我" inside the heard fold |
| `record_unavailable` for my `utt_id` | meta under my bubble "已送达，记录未保存" |

- Date separators per day; time stamps when more than 10 min pass between rows (display only).
- Delivery meta under my last row: 发送中 → 已送达 (receipt or voice 200 carries `utt_id`).
- Long press on a bubble: Copy, Share; on my failed row also Retry and Delete draft.
- Links and phone numbers are detected (`AttributedString` + data detectors). No markdown rendering in
  v1 (the room prompt asks for no markdown); Q10.

### 4.4 多多 working (screens `chat-working`)

Driven by `turn` frames on the display socket, scoped to the pending turn.

```
send / voice 200 ──▶ working bubble "收到了"         (turn received)
                     ├─ "在想" + dots                (turn thinking, ≤ 1 per 2 s)
                     ├─ "在查" + step list           (turn tool: label, input_summary; "✓" result)
                     ├─ streaming text + caret        (duoduo_said deltas, same speech_id)
                     └─ final bubble                  (answer_final, replaces the stream)
```

- The working bubble sits where the answer will appear and turns into it; no jump.
- Tool steps follow the Feishu channel's process card. Per call the channel sends three `tool`
  frames: `label` = tool name (claude's early call, no input), `label` + `input_summary` (the
  input as raw JSON), `label` = `<name> ✓` (the result). They make one step; the result marks the
  oldest open step of that name done (the channel drops `tool_use_id`, so parallel calls of one
  tool pair up in order). Raw JSON is never shown.
- Step line = `<name> <summary>` (`PocketCore.ToolLine`): `mcp__<server>__<tool>` shows `<tool>`;
  the summary is the first non-empty string among `description`, `command`, `file_path`, `path`,
  `pattern`, `query`, `url`, `prompt`, `text`, then `files[0]`, then the first string value in
  key order; whitespace collapsed, cut to 34 characters with "…". Input that is not JSON shows as
  text, cut the same way.
- While working the card is bounded, as Feishu keeps its panel collapsed while running: row 1 is
  the phase (收到了 / 在想 / 在查) with 「+N 步」 for the earlier steps; row 2 is the current step
  (spinner while it runs), one line. Two rows at most at every text size.
- After the answer: one line above the answer bubble, 「任务已完成 · N 步 · 23 秒」 (Feishu's
  finished title plus count and time from the turn's first frame to `answer_final`), with a
  chevron. Tap opens 「执行工具」 and every step, uncapped (Feishu keeps the whole archive); the
  thread scrolls the opened row to the top, because the bottom scroll anchor would otherwise push
  it up off screen. No steps, no line. The line sits outside the bubble so the bubble's long-press
  menu never covers it. Not persisted: after a relaunch an answer shows without its steps.
- Correlation: `answer_final.utt_id` equals the inject receipt / voice `utt_id`. Answer log rows
  carry the `utt_id` they answer (channel 09f9076); a row naming another utterance is never this
  one's answer, a row without `utt_id` after this utterance's row still counts (older rows,
  proactive messages). The brain runs one turn at a time and folds notes sent while it works into
  that turn, answering the first note's `utt_id`: an `answer_final` / `idle` for another
  utterance ends the bubble once the bubble has seen the turn work (a bubble still at 收到了 is
  kept); a queued note's own turn brings it back with its first `thinking` frame.
- Order: a live answer whose log row has not arrived sits at the time it arrived, among the log
  rows, as its row will; so a note sent after it stays below it, live and after a catch-up alike.
  The live bubble and its log row share one row id (`ans:<utt_id>`), so the row is updated in
  place when the log row lands.
- Scrolling: while the end of the thread is on screen, every change scrolls to the end after
  layout. The bottom anchor alone could leave the lazy stack showing a blank stretch after a long
  row was replaced.
- End without answer: the channel today emits `turn done` only after playback. A text-only turn
  that ends with no answer leaves the bubble spinning. The link contract (`docs/ble-protocol.md` §9) needs
  `turn idle` too (Q7). Until then the bubble falls back to "多多没有回复" when the next
  `turn` for another utterance starts or on reconnect catch-up.

### 4.5 Text and attachments (screens `attachments`, `attach-menu`)

- Composer, hold-to-talk mode (default on first launch): keyboard toggle · wide 按住说话 bar · `+`,
  plus a send arrow while attachment chips are present. Text mode: mic toggle · growing text field
  (max 6 lines then scroll) · `+` · send arrow when there is text or an attachment. The toggle
  switches modes; the last chosen mode is stored (`composer.voice`) and restored on launch. A text
  draft is kept but neither shown nor sent while in hold-to-talk mode.
- `+` menu: 照片 (PHPicker, multi-select), 拍照 (camera), 文件 (document picker).
- Chips above the field: image thumbnails / file tiles, ✕ to remove, per-chip upload progress.
  Upload starts when the chip is added (not at send) so send is fast; cached by file identity.
- Send = all chips uploaded (`POST /api/upload`) → `POST /api/inject {text, attachments}`.
  Failure keeps the draft and chips; the row shows "没发出去 · 轻点重试".
- 413 from upload → chip turns attention: "文件太大（上限 N MB）". The limit is unknown to the app
  before upload (Q8).
- Images in the thread load via `GET /api/attachment?sha256&mime&name` (immutable, cached on disk);
  tap opens a full-screen viewer with share. Files open in Quick Look after download.
- Files 多多 sends: the brain queues them in-turn (`QueueOutboundAttachment`); the daemon puts them on
  the outbox record as `payload.attachments: {path, mime}[]`. The channel fetches each once
  (`channel.file.download`), files it under the room's `attachments/<sha256>` beside uploads, and
  appends one row `{speaker:"多多", kind:"answer", text:"", attachments:[{name, mime, sha256}]}`
  (live `imlog_append`, then history). A file the channel could not fetch keeps its name without
  `sha256` and shows as a disabled card. These rows stay out of the judge's and the brain's room
  context.

### 4.6 Hold-to-talk (screens `hold-record`, `hold-cancel`, `voice-states`)

| Phase | Gesture | UI |
|---|---|---|
| Idle | — | 按住说话 bar in the composer (hold-to-talk mode) |
| Too short | release < tap threshold, or while preparing | tooltip "按住说话"; nothing sent; cancel haptic (threshold: Q4, 300 ms) |
| Preparing | touch down on the bar | in the touch's own frame (probe: drawn 11 ms median after the handler, 4-20 ms): the bar under the finger is pressed (scale 0.97, darker fill, label 按住说话) and the sheet pops up in a preparing state: 「准备中…」 instead of the timer, dimmed flat placeholder bars breathing (opacity 0.25-0.6, 1.1 s period; static at 0.43 with Reduce Motion), hint 「麦克风就绪后会轻震一下」. No haptic. Lasts until the input starts (about 0.25 s on the speaker route, 17 Pro Max; instant while ambient is on) |
| Recording | the microphone input starts capturing | 0.12 s cross-fade to live: timer starts, waveform follows the mic, the bar turns teal 「松开发送」, hint 「松开发送 · 手指移出按钮取消」; the light haptic fires in the same view update as the switch (probe: within 1-9 ms of the live sheet being drawn). Nav subtitle 在听你说 |
| Cancel armed | finger leaves the bar's frame (any direction), preparing or recording | middle of the sheet shows the cancel target: × in an attention circle and "松手取消"; hint "移回按钮继续录音"; the bar greys; haptic tick |
| Resumed | finger moves back onto the bar | timer and waveform return, bar teal again "松开发送"; haptic tick |
| Cancelled | release off the bar | sheet drops, nothing sent, audio discarded |
| Sending | release on the bar | sheet drops; my voice bubble appears dimmed with waveform + spinner, meta "正在识别…" |
| Transcribed | `/api/voice` 200 `{text, utt_id}` | bubble shows transcript; working bubble starts |
| Didn't catch | 422 `empty_transcript` | bubble removed, centre note "没听清，再说一次" |
| ASR failed | 502 `asr_failed` | failed bubble: "识别出错 · 轻点重试" |
| Not sent | network / 503 after retries | failed bubble: "没发出去 · 轻点重试"; packets kept, retry reuses the same `X-Voice-Id` |

- Touch delivery: the bar handles raw UIKit touches (`touchesBegan`), not a SwiftUI drag
  gesture, and the conversation defers the bottom-edge system gesture
  (`defersSystemGestures(on: .bottom)`), because the bar sits just above the home indicator,
  where iOS otherwise holds a touch back until it has ruled out a home swipe. Cost: going home
  from the conversation takes a second swipe (the first shows the indicator). `hold_timing`
  logs `touch_age_ms`: the touch's hardware timestamp to the handler.
- VoiceOver: the mic becomes a toggle (double-tap start, double-tap send, escape cancels); Magic
  Tap (two-finger double tap) does the same from anywhere in the conversation.
- Retries are idempotent by `X-Voice-Id` (`docs/ble-protocol.md` §2); the existing `VoiceUploader` already does this.
- Incoming call / Siri during recording: recording stops and is kept as a failed-to-send draft.

#### 4.6.1 Audio session for hold-to-talk

- No pre-warm, no always-on mic. The session activates and the engine is built and started at
  the press. Pre-warming the session and a prepared engine (no indicator) was built and measured
  and removed by user decision: it saved about 20 ms (first tap buffer median 342 → 323 ms),
  because a prepared engine on an idle session starts slower (about 205 ms against 170 ms right
  after activation).
- "Speak now" (start haptic, timer, `holdLive`) fires when `AVAudioEngine.start` returns: the
  first sample's capture time is 3-5 ms before that, so speech from then on is in the note. The
  tap delivers 100 ms blocks (4,800 frames at 48 kHz; iOS ignores smaller tap sizes), and waiting
  for the first block put the haptic about 117 ms after recording began. The waveform still moves
  from the first block.
- Measured (17 Pro Max, speaker route, hold probe, 15 presses, median ms from touch): live
  (haptic, timer) 344 → 270; session active 55, engine running 245, first sample 240, first tap
  buffer 358, first waveform 384. The input start itself (about 170-200 ms) is the floor.
- Other audio: the note session uses `.duckOthers` (which mixes): other apps keep playing, ducked
  while the note records; the release deactivates the session, which is when iOS lifts ducking.
- Microphone when AirPods are connected (Settings › 声音): phone microphone (default) or AirPods
  microphone. Phone microphone: no `.allowBluetoothHFP`, `.allowBluetoothA2DP` kept, so AirPods
  stay in A2DP and play on. AirPods microphone: the press builds a fresh engine with
  `.allowBluetoothHFP` (AirPods switch to HFP for the note).
- Ambient mode is unchanged: `.voiceChat` with `.allowBluetoothHFP`, not mixable, so AirPods go to
  HFP while ambient is on whatever the setting says. A hold during ambient records from the
  ambient engine and changes nothing in the session.

### 4.7 Ambient mode (screens `ambient-call`, `ambient-chat`)

Two presentations of one state:

- Ambient view (full screen, opened when ambient turns on): big dog in the current pose with level
  rings, phase title (在听 / 在想 / 在查 / 正在说), while a tool runs the current step line
  (§4.4, subheadline, two lines at most), sub-line ("说话就能打断它" while speaking), live
  caption card of the current answer, last heard line, and four controls: 静音, 别说了 (only enabled
  while speaking), 对话 (minimise), 关闭.
- Ambient pill (minimised, in the conversation): teal pill under the nav bar with the level meter,
  phase, route ("扬声器 · 回声消除已开"), 别说了 and ⏻. Tap expands to the ambient view.

| Ambient sub-state | Source | Display |
|---|---|---|
| Starting | engine starting, socket opening | "正在打开麦克风…" |
| Listening | `role: master`, `meta.state: listening`, uplink live | 在听, level rings follow RMS |
| Heard | `transcript` frame | heard line updates |
| Thinking / tool | `turn` frames | 在想 / 在查, step line below (§4.4) |
| Speaking | local playback of a `c-` speech | 正在说, caption grows with `duoduo_said` |
| Filler | local playback of an `s` speech | 正在说, no caption |
| Muted | user tapped 静音 | `muted` pose, "已静音，房间听不到" |
| Seat taken | `role: peer` (another edge in the same room) | "另一台设备在听" + 在这台手机上听 (re-hello) |
| Deaf | `meta.state: unowned` while on, or mic revoked | `deaf` pose, "听不到了" + 重新打开 |
| Interrupted | `AVAudioSession` interruption | "来电，已暂停" ; resumes when the system says it may |
| Off | user, or app left foreground (Q3) | pill disappears; answers are text only |

### 4.8 Passport chip and sheet (screens `passport-sheet`, `passport-pair`)

Nav chip: status dot + device glyph + battery % (or 未配对 / 未连接 / 版本不匹配). Tap opens the sheet
(medium/large detents).

| Section | Content | Source |
|---|---|---|
| Hero | device drawing, name, link state, last press time | `PassportLink.onState`, press log |
| Stats | battery %, charging (0/1/0xFF = 未知 "本机无法检测") | `INFO`, `STATUS` |
| Passport 正在显示 | latest reply text, time, "已送达设备" / "等待连接后发送" | `ReplyTracker.lastAnswer` |
| Device | firmware, link protocol, pre-roll (read-only; set on the device) | `INFO` |
| Actions | 重新配对 · 导出 Passport 日志 · 忘记此设备 (destructive, confirm) | |

Error states inside the hero: 未连接 (out of range, "靠近手机会自动连上"), 版本不匹配 (`APP_STATE 2`,
"请更新多多随身或设备固件"), 蓝牙关闭 (button to Settings).

Pairing sheet: scan list → connect → iOS numeric-comparison alert; behind it the app explains
"核对两边的数字，先在 Passport 上按 OK，再在 iPhone 上点「配对」"; troubleshooting footnote for
a previously paired device (forget it in iOS Settings › Bluetooth).

### 4.9 Settings (screens `settings`)

Grouped list. Editing host/room/port/TLS reruns the onboarding step-2 check inline before saving.
Sound: 连着 AirPods 时用 手机麦克风 (default) / AirPods 麦克风 (§4.6.1).
Tailscale row: state, node name, IP, 退出登录 (confirm). Diagnostics: export logs (app log +
tsnet log + Passport log as one share sheet), version.

### 4.10 Errors (copy)

| Condition | Copy | Action |
|---|---|---|
| Upload / inject network failure | 没发出去 · 轻点重试 | retry same id |
| 422 empty transcript | 没听清，再说一次 | — |
| 502 asr_failed | 识别出错 · 轻点重试 | retry |
| 503 cerebellum_unavailable | 语音服务暂不可用 | retry later |
| 413 | 文件太大 | remove chip |
| Mic permission denied | 需要麦克风权限才能说话 | 去设置 |
| Bluetooth off / denied | 蓝牙已关闭，Passport 连不上 | 去设置 |
| Protocol mismatch | 版本不匹配 | update |

## 5. Accessibility

- Every row has a combined label: "多多，09:39：…", "我，语音，6 秒：…", "发送失败，可重试".
- State changes are announced (throttled to one per phase change): "多多在想", "多多在查日历",
  "多多回复了".
- Hold-to-talk alternatives: toggle mode for VoiceOver and Switch Control; Magic Tap.
- Ambient controls are large (64 pt) and labelled; 别说了 is a custom rotor action while speaking.
- Dynamic Type up to AX5: bubbles reflow, nav subtitle truncates, settings cells stack.
- Nav bar centre: the centre item is as wide as 多多 alone, so UIKit always centres it; the
  subtitle is drawn under it, centred, truncated to the width that clears the side items.
- Contrast: brand on paper 5.2:1, text ramps ≥ 4.5:1 for body; colour is never the only signal.
- Reduce Motion: static poses, no ring animation; Reduce Transparency: opaque bars.

## 6. Endpoint map

All requests go over tsnet (`Tailnet.request` / native WS), never through the loopback proxy, which
is removed with the web view.

| Feature | Endpoint / frame | Notes |
|---|---|---|
| Health check (onboarding, Passport `APP_STATE`) | `GET /healthz` | `{ok, rooms}` |
| Initial state + recent history | `GET /api/state?room=` | `imlog` last 80, `daemon_ok`, `cerebellum_ok`, `capture.owner`, `controls`, `room_name`, `date` |
| Older history | `GET /api/imlog?room=&date=YYYY-MM-DD` | one day per request, walked backwards while the user scrolls up |
| Live updates (always) | WS `/live?room=` without `hello` | `imlog_append`, `turn`, `duoduo_said`, `answer_final`, `transcript`, `playback`, `tts_interrupted`, `record_unavailable`, `cerebellum`, `meta{state}`, `understood`/`wake_ignored`/`ack_silenced` |
| Typed text | `POST /api/inject?room=` `{text, attachments?}` | 200 `{ok, utt_id, at, record_available}` |
| Attachment upload | `POST /api/upload?room=&name=` (raw body, `Content-Type` = mime) | 200 `{name, mime, path, sha256}` → goes into `inject.attachments` |
| Attachment display | `GET /api/attachment?room=&sha256=&mime=&name=` | immutable, cache forever |
| Hold-to-talk and Passport voice notes | `POST /api/voice?room=` (`application/vnd.ambient.opus-packets`, `X-Voice-Id`, `X-Voice-Source: phone\|passport`) | 200 `{voice_id, text, utt_id}`; 422/502/503/400/413 |
| Ambient edge | second WS `/live?room=` with `hello{edge:"client", aec}` | section 7 |
| Ambient mute | edge frame `mute{on}` | `on` is the room's capture switch: `on:true` = mic on, `on:false` = muted |
| Ambient "别说了" | edge frame `hush` + local stop | |
| Playback receipts | edge frame `played{speech_id, ms}` | watermark, not delta |

Gaps found in the current channel (branch `feature/pocket-voice-note`):
- No `turn idle` / end-of-turn-without-answer frame (Q7).
- Upload size limit is not exposed before upload (Q8).
- `/api/state` returns only today's last 80 rows; scroll-back uses `/api/imlog` per day, which has no
  cursor for days with many rows (acceptable: one day is one file).

## 7. Native ambient edge

### 7.1 Sockets

```
display socket  /live?room=   no hello   always on while foreground or awaiting a reply
edge socket     /live?room=   hello      only while ambient is on
```

- Two sockets because a socket cannot un-hello: closing the edge socket is how the seat is released
  at once (`EdgeHub.remove`), while the display socket keeps the conversation and the Passport reply
  path untouched. Broadcast frames arrive on both; the edge socket consumes only audio-plane frames
  (`audio_params`, `speech`, binary, `stop_audio`, `meta{role,state,conn}`) and ignores the rest.
- Alternative (one socket that hellos when ambient turns on, reconnects without hello when it turns
  off) is listed in Q11.
- `Bridge/tsbridge` today has one text-only WS. It needs a second WS handle with binary send and
  receive (one Opus packet per binary frame, ≤ 1 MiB per message).

### 7.2 Handshake (same rules as the web edge, `capture.js` / `transport.js`)

1. Open the socket; receive `meta{conn}`.
2. Start capture. Send `hello{type:"hello", room, conn, edge:"client", aec}` only after the first
   encoded packet exists: a seat without audio makes the room deaf.
3. Receive `meta{role}` then `audio_params{rate:16000, frame_ms:120}`. `rate` ≠ 16000 → warn and stop.
4. `role: "peer"` → do not stream; show "另一台设备在听" with a takeover that re-sends `hello`.
5. On reconnect (`meta{conn}` again) while capturing: re-send `hello`; if the mic is dead, re-acquire
   first.
6. Seat lease: the channel drops a master after `seat_starve_ms` (15 s in the shipped config) without
   audio, so uplink is continuous while on (DTX off, `docs/ble-protocol.md` §1).

### 7.3 Audio session and engine

| Item | Choice | Why |
|---|---|---|
| Category / mode | `.playAndRecord`, `.voiceChat` | enables the voice-processing I/O unit: echo cancellation, AGC, noise suppression |
| Options | `.defaultToSpeaker`, `.allowBluetoothHFP` | speaker by default (voiceChat defaults to the receiver); AirPods in HFP work |
| Engine | one `AVAudioEngine`, `inputNode.setVoiceProcessingEnabled(true)`; playback through an `AVAudioPlayerNode` on the same engine | AEC needs the played signal as its reference; a separate player bypasses it |
| `aec` in `hello` | `true` only if voice processing was enabled and not bypassed | the protocol makes echo cancellation the edge's obligation |
| Other audio ducking | `setVoiceProcessingOtherAudioDuckingConfiguration` minimal | VPIO otherwise ducks other apps hard |
| Capture | tap → convert to 16 kHz Int16 mono → `OpusVoiceEncoder` (20 ms, complexity 0, VBR, DTX off, FEC off) → one binary frame per packet | `docs/ble-protocol.md` §1; encoder in `PocketOpus` |
| Level meter | RMS of the frames already captured, O(1) per frame, published at display rate only while foreground | background CPU rule |
| Route change | rebuild the engine, re-evaluate `aec`, re-hello if it changed | |
| Media services reset | rebuild everything | |

### 7.4 Playback (downlink)

Rules from `audio-link.js`, which the native edge must keep:

1. Binary frames belong to the `speech_id` of the latest `speech{speech_id}` frame. A binary frame
   before any `speech` is dropped.
2. Decode with `OpusVoiceDecoder` (16 kHz), schedule buffers on the player node.
3. Report `played{speech_id, ms}` as a cumulative watermark from buffer completion callbacks (not
   from scheduling), every 250 ms (the web cadence) and once at drain. The channel leaves SPEAKING
   only when `played ≥ audio_ms`.
4. `stop_audio{speech_id?, reason}`: stop at once if the id is an answer (`c-…`) or absent while an
   answer plays; let fillers (`s…`) finish. No `played` after a stop for that id. Reset the decoder.
5. 别说了 (local hush): stop everything locally, including fillers, then send `hush`.

Barge-in needs nothing extra on the phone: with echo cancellation the user's voice reaches the
cerebellum, which decides and the channel sends `stop_audio{reason:"barge_in"}`.

### 7.5 Interaction with hold-to-talk and the Passport

- Hold-to-talk while ambient is on: send `mute{on:false}` (room mic off), keep the uplink flowing
  (the channel drops it while the mic is off; the seat lease would expire in a long press
  otherwise) and record the voice note from the same capture, then `mute{on:true}` on release. Without this the same speech enters
  the brain twice (voice note + room judge). Q12.
- Passport press while ambient is on: the phone mic hears the user too; send `mute` between
  `PRESS_START` and `PRESS_END` for the same reason. Q12.
- 静音 in the ambient view sends `mute{on:false}` and stops sending bytes (privacy: bytes do not leave
  the phone). After `seat_starve_ms` the seat goes `unowned`; the UI shows muted, not deaf.

### 7.6 Lifecycle and background

- Foreground: as above.
- App leaves the foreground: depends on Q3. With only `bluetooth-central`, iOS
  suspends capture; the app closes the edge socket on `scenePhase == .background` so the seat is
  released at once and answers become text (`unspoken` rows). On return it does not reopen ambient
  automatically unless Q3 says so.
- Interruptions (call, Siri, alarm): stop capture, close the edge socket, show 已暂停; on
  `.ended` with `.shouldResume` reopen and re-hello.
- Thermal state ≥ serious: show a note; no automatic shutdown in v1.
- Answers for the Passport (no APNs): every answer the app receives is
  forwarded as REPLY, with or without a pending press: live on the display socket (foreground,
  reply wait, ambient), from the room log when the Passport link comes up (BLE wake) and from
  Background App Refresh (`BGAppRefreshTask` `dev.openduo.pocket.refresh`, scheduled on
  every move to the background with no earliest time; iOS decides when). Details in
  `docs/ble-protocol.md`.
- All per-frame work is O(append); SwiftUI updates only while active (repository rule).

## 8. Offline cache and history

- Store: one JSON file per room per day (`imlog-YYYY-MM-DD`), replaced whole when fetched.
  Today is replaced on every `/api/state` and patched live from `imlog_append`; past days are
  replaced when re-fetched. Nothing is merged locally beyond pending rows.
- Local pending rows (unsent text, voice notes, uploads) live in a separate queue file and are shown
  until a server row with the same `utt_id` arrives (or, for not-yet-sent rows, until sent).
- Launch shows the cache instantly; the network result replaces it without moving the scroll
  position.
- Retention: Q13.

## 9. Code structure

```
App/
├── Engine/   PocketEngine (Passport, voice notes) · ConversationStore · AmbientController ·
│             AudioIO · HoldTiming
├── Device/   PassportLink (BLE central)
├── Net/      Tailnet (tsnet, display and edge sockets) · ChannelClient (typed calls for section 6)
├── Support/  Settings · AppLog · Demo (Debug fixtures and probes)
└── Views/    ConversationView · ThreadView · Composer · AmbientView · PassportSheet ·
              SettingsView · OnboardingView · AttachmentViews · Theme
Packages/PocketKit/   PocketCore (link codec, edge state machine, thread, cache, outbox) ·
                      PocketOpus
```

`ConversationStore` is the single source for the thread (cache + live frames + pending queue) and
is shared by the Passport reply path, so the Passport and the screen never disagree.

## 10. Open questions

| # | Question | Options | Trade-off | Recommendation |
|---|---|---|---|---|
| Q1 | Bubble shape vs the square duoduo system | a) iOS-native 19 pt rounded bubbles (mockups) · b) near-square 4 pt plates with hairlines, web-like · c) no bubbles for 多多, plain text column; bubbles only for me | a) instantly familiar, departs from the web system · b) on-brand, reads as a document, less "IM" · c) good for long answers, less Messages-like | a |
| Q2 | Where ambient lives | a) nav-bar button → full-screen ambient view, minimisable to a pill (mockups) · b) pill only, never full screen · c) a mode switch inside the composer | a) clear "call" mental model, more UI · b) minimal, weak state feedback · c) crowds the composer | a |
| Q3 | Ambient after leaving the app / locking | a) foreground only; turning off on background (the v1 scope as first written) · b) add `audio` background mode, keep listening while locked, with a Live Activity | a) simple, no review or battery risk, ambient stops in the pocket · b) a real "always listening" phone; battery, App Store 2.5.4 scrutiny, CPU budget in background | a for v1, b as a later trial |
| Q4 | Hold-to-talk minimum length | a) 300 ms like the Passport · b) none, any press is speech (as the app treats Passport presses, `docs/ble-protocol.md` §7) | a) avoids accidental empty notes · b) consistent with the device; empty notes return 422 anyway | a, as a named tuning value |
| Q5 | Sending while offline | a) queue text and voice notes, send on reconnect (screens `offline`) · b) block the composer while offline | a) no lost thoughts; late delivery can surprise · b) honest, loses input | a, with "等待连接" meta and per-row cancel |
| Q6 | Ambient room speech in the thread | a) compact heard rows + folds (mockups) · b) hide room speech, show only 多多's answers · c) full bubbles per speaker | a) context without noise · b) cleanest, loses why 多多 answered · c) noisy | a |
| Q7 | End of a turn with no answer | a) channel adds `turn {phase:"idle"}` (the link contract needs it too) · b) client timeout · c) leave spinning until the next turn | a) exact, small channel change · b) a magic number · c) misleading | a |
| Q8 | Upload size limit | a) expose `upload_max_bytes` in `/api/state` · b) learn from the first 413 · c) client-side constant | a) correct up front, additive field · b) one wasted upload · c) drifts from the server | a |
| Q9 | When to show the offline banner | a) after the first failed reconnect attempt · b) after a fixed delay · c) immediately | a) no constant, avoids flashing on wake · b) needs a number · c) flashes on every wake | a |
| Q10 | Markdown in answers | a) plain text (room prompt asks for none) · b) render a safe subset (bold, lists, links) | a) consistent with the Passport · b) better for long answers if the prompt changes | a |
| Q11 | Ambient socket model | a) separate edge socket (section 7.1) · b) one socket: hello when on, reconnect without hello when off | a) clean seat release, display path never interrupted, needs a second WS in tsbridge · b) one WS, but every toggle drops live frames briefly | a |
| Q12 | Phone mic during hold-to-talk / Passport press in ambient mode | a) `mute` the edge for the press (section 7.5) · b) keep streaming and accept double ingress · c) turn ambient off for the press | a) no duplicates, uses an existing frame · b) duplicates in the brain · c) seat loss and re-hello churn | a |
| Q13 | Cache retention | a) keep everything · b) keep N days · c) keep only what fits a size budget | a) simplest, grows forever · b/c) need a number | a for v1; revisit with data |
| Q14 | App icon and name treatment | a) dog `listening` pose on paper · b) dog on teal · c) wordmark | brand recognition vs legibility at 60 pt | decided: a line-drawn curly pompom around voice bars on cream, no face; source in `docs/design/icon/final/` |

## 11. Screens

Debug builds render each screen from fixtures: launch with `-PocketDemo <screen>` (add
`-ui.appearance dark` for dark mode). `DEVICE_UDID=<udid> scripts/render-screens.sh` captures
every screen below in light and dark from a connected iPhone. The pre-implementation mockups are
not part of the repository.

| Screen | Shows |
|---|---|
| `empty` | first conversation, three ways to talk |
| `chat-working` | history, Passport voice note, 多多 working with tool steps |
| `chat-done` / `chat-done-tap` | answered steps: collapsed line; the list opened after 1 s through the real toggle |
| `voice-states` | failed voice note, didn't catch, uploading, streaming answer |
| `composer-voice` / `composer-text` | hold-to-talk default and text mode |
| `hold-preparing` / `hold-record` / `hold-cancel` | hold-to-talk preparing, recording, cancel armed (§4.6) |
| `duoduo-files` | a file row from 多多 |
| `attachments` | image and file rows, composer chips with upload progress |
| `ambient-call` / `ambient-chat` / `ambient-tool` | ambient full view while speaking; minimised pill with heard rows; a long tool step |
| `passport-sheet` / `passport-pair` | device status and latest reply; numeric-comparison pairing |
| `settings` | settings list |
| `onboard-tailnet` / `onboard-connect` | onboarding steps 1 and 2 |
| `offline` | offline banner, cached thread, queued message |
| `live-long-answer` | a long streaming answer pinned in the thread |

Host, room and device names in the fixtures are placeholders; a fixture launch never shows the
stored channel settings. The attach menu (+) is a system menu and has no fixture.
