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
- Live mark: the 多多 mark (`LogoMark`, the openduo.ai mark) in place of an avatar. It appears only
  where it is the content: the empty state, onboarding, the ambient view and the iPhone Duo room.
  The nav bar carries 多多's live state as text (the subtitle); no avatars beside bubbles. Motion
  says what 多多 is doing and a halo behind the coat says it in colour, readable from across a room:

| State | Mood | Mark | Halo | Nav subtitle |
|---|---|---|---|---|
| online, idle / connecting | `idle` | dozes, bars low | none | 在线 / 连接中… |
| ambient listening (also 静音) | `listening` | head cocked | teal, follows the microphone | 环境模式 · 在听 |
| hold to talk | `hearing` | head cocked further | teal, strong, follows the microphone | 在听你说 |
| `turn received` / `thinking` / `tool` | `thinking` | bars ripple slowly | violet, slow pulse | 收到了 / 在想… / 在查 |
| `duoduo_said` streaming | `speaking` | bars talk | pink, steady pulse | 正在回复 |
| playback (ambient) | `speaking` aloud | bars follow the playback level | pink, follows the playback | 正在说 |
| offline, not set up, unpaired, deaf, paused | `unavailable` | grey and still | none | 连不上 · 正在重试 … |

- Motion: the mark is drawn every frame; the level it follows is eased between audio blocks.
  Reduce Motion draws it still; the halo keeps its colour, so the state still reads.
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
| 1 Tailscale | The mark (`idle`), "先连上你的网络", one line on why, node name `duoduo-pocket`. Button 登录 Tailscale opens `auth_url` from `TsbridgeStatus` in `ASWebAuthenticationSession`. While waiting: "已在浏览器打开登录页，完成后回到这里", polling `backend_state`. | `backend_state == Running` |
| 2 Find 多多 | Host, room; port + HTTPS collapsed under one row. Live checklist: Tailscale connected → `GET /healthz` 200 (latency shown) → `GET /api/state?room=` 200, `daemon_ok`, `cerebellum_ok`. A 400 with `rooms` offers the room names as suggestions. | all three checks pass; 稍后再说 allowed |
| 3 Passport | Same as the pairing sheet (4.9). Skippable. | paired or skipped |

Permissions are requested in context, not up front: microphone on first hold or first ambient on;
Bluetooth on step 3 or the first Passport action; Photos/Camera on first use.

### 4.2 Conversation states

| State | Trigger | What the user sees |
|---|---|---|
| Empty | connected, history empty | The mark (current mood), "我在，随时说", three cards: hold to talk, ambient mode, add Passport (screens `empty`) |
| Connecting | launch, foreground, settings change | Cached thread at once; nav subtitle 连接中…; no banner for the first 2 s (Q9) |
| Connected | `/live` socket open and `/api/state` 200 | Nav subtitle 在线 |
| Offline | socket cannot be restored, request fails | Attention banner "连不上多多 · 显示 HH:MM 缓存的记录" + 重试; nav subtitle 连不上 · 正在重试; sends are queued (Q5) (screens `offline`) |
| Tailnet login needed | `backend_state == NeedsLogin` | Banner "需要重新登录 Tailscale" + 登录; nothing else changes |
| 多多 cannot reply | `/api/state.daemon_ok == false` | Banner "多多暂时无法回复，消息会先记下"; sending still allowed |
| Voice unavailable | `cerebellum_ok == false` or `cerebellum` frame `ok:false` | Mic and ambient button dimmed; tap explains "语音服务暂不可用"; typing still works |
| Config issue | `/api/state.config_issues` non-empty | Diagnostics row in Settings only; not a user banner |

### 4.3 Thread rows

Built from room-log rows (server authority, keyed by `seq`) plus local rows that have not yet
appeared there.

| Entry | Row |
|---|---|
| `kind: "typed"`, no `voice_source` | my text bubble (+ attachments above it) |
| `kind: "typed"`, `voice_source: "phone"` | my voice bubble: head "语音 · 0:06", the text the brain received |
| `kind: "typed"`, `voice_source: "passport"` | my voice bubble with Passport glyph |
| `kind: "answer"` / speaker `多多` | 多多's bubble; spoken rows get "已播报", `truncated` shows `full_text` (the whole answer) with "只播了一部分", `unspoken` gets nothing |
| speaker `多多`, empty `text`, `attachments` | files 多多 sent (outbox `payload.attachments`, filed by the channel): images inline, files as cards, no spoken meta; never a Passport reply |
| `kind: "reaction"` | not shown in the thread (fillers like 「我看看」) |
| `kind: "human"` (ambient room speech) | compact "heard" row: speaker chip `V1` + text, not a bubble; runs of more than 3 fold into "房间里还说了 N 句" (Q6) |
| `understood addressed:false` / `wake_ignored` / `ack_silenced` | folded note "听到了，不是在叫我" inside the heard fold |
| `message failed(brain_unreachable)` for my message (live) | meta under my bubble "没送到多多"; the row stays (the record is append-only) |

- Date separators per day; time stamps when more than 10 min pass between rows (display only).
- Delivery meta under my last row: 发送中 → 已送达 (202 accepted; the row whose `utt_id` is the
  message id replaces the pending row).
- Long press on a bubble: Copy, Share; on 多多's bubble also Reply and 朗读 (read aloud, §7.7); on
  my failed row also Retry and Delete draft.
- Links and phone numbers are detected (`AttributedString` + data detectors). No markdown rendering in
  v1 (the room prompt asks for no markdown); Q10.

### 4.4 多多 working (screens `chat-working`)

Driven by `turn` frames on `/live`, scoped to the pending turn.

```
message delivered ──▶ working bubble "收到了"        (turn received, message_ids)
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
- Correlation: by `message_ids` on `turn`, `answer_final` and answer rows: the messages the
  turn covered (the brain folds messages sent while it works into the running turn, so one turn
  can cover several). `turn received` starts the bubble with its messages, and later deliveries
  join it. An `answer_final` or `idle` naming one of the bubble's messages ends it (any one, for a
  bubble of room speech without messages); an answer to other inputs leaves the bubble.
- Order: a live answer whose log row has not arrived sits at the time it arrived, among the log
  rows, as its row will; so a note sent after it stays below it, live and after a catch-up alike.
  The live bubble and its log row share one row id (`ans:<message_ids>`), so the row is updated in
  place when the log row lands.
- Scrolling: while the end of the thread is on screen, every change scrolls to the end after
  layout. The bottom anchor alone could leave the lazy stack showing a blank stretch after a long
  row was replaced.
- End without answer: `turn idle` naming the bubble's messages ends it. After a reconnect,
  `ready.turn` restores the open turn's bubble or clears one whose turn ended meanwhile.

### 4.5 Text and attachments (screens `attachments`, `attach-menu`)

- Composer, hold-to-talk mode (default on first launch): keyboard toggle · wide 按住说话 bar · `+`,
  plus a send arrow while attachment chips are present. Text mode: mic toggle · growing text field
  (max 6 lines then scroll) · `+` · send arrow when there is text or an attachment. The toggle
  switches modes; the last chosen mode is stored (`composer.voice`) and restored on launch. A text
  draft is kept but neither shown nor sent while in hold-to-talk mode. While ambient mode is on the
  composer shows text input only (the toggle is hidden, the hold bar off): the room already hears
  the phone. The stored mode returns when ambient mode ends.
- `+` menu: 照片 (PHPicker, multi-select), 拍照 (camera), 文件 (document picker), 位置 (map).
- 位置 opens a map on the current location (when-in-use permission; a denied permission leaves the
  map draggable). The pin is the map's centre; dragging the map or a search (`MKLocalSearch` over
  the visible region) moves it. 使用这个位置 inserts one line into the draft, so no wire field is
  added: `📍 <name>，<address>（地图坐标：lat, lon）`, plus `，大致位置` when the user allowed only an
  approximate fix and the pin is still on it. The coordinates are Apple Maps' own: GCJ-02 where
  the map data is Chinese (mainland and Hong Kong, measured), WGS-84 elsewhere, with no reliable
  signal for which, so they are labelled map coordinates rather than a datum.
- Chips above the field: image thumbnails / file tiles, ✕ to remove, per-chip upload progress.
  Upload starts when the chip is added (not at send) so send is fast; cached by file identity.
- Send = all chips uploaded (`POST /api/upload`) → `POST /api/messages {text, attachments}`
  (JSON, `Idempotency-Key` = the outbox item's id, kept across retries and relaunches). 202
  accepts it; its row arrives on `/live` at delivery. A network error keeps the message queued
  until the connection returns. Any other failure, a 5xx included, is not retried automatically:
  the row shows "没发出去 · 轻点重试", and tapping it resends under the same `Idempotency-Key`.
- 413 from upload → chip turns attention: "文件太大（上限 N MB）". The limit is unknown to the app
  before upload (Q8).
- Images in the thread load via `GET /api/attachment?sha256&mime&name` (immutable, cached on disk);
  tap opens a full-screen viewer with share. Files open in Quick Look after download.
- Files 多多 sends: the brain queues them in-turn (`QueueOutboundAttachment`); the daemon puts them on
  the outbox record as `payload.attachments: {path, mime}[]`. The channel fetches each once
  (`channel.file.download`), files it under the room's `attachments/<sha256>` beside uploads, and
  appends one row `{speaker:"多多", kind:"answer", text:"", attachments:[{name, mime, sha256}]}`
  (live `row`, then history). A file the channel could not fetch keeps its name without
  `sha256` and shows as a disabled card. These rows stay out of the judge's and the brain's room
  context.

### 4.6 Hold-to-talk (screens `hold-record`, `hold-cancel`, `voice-states`)

| Phase | Gesture | UI |
|---|---|---|
| Idle | — | 按住说话 bar in the composer (hold-to-talk mode; not while ambient mode is on) |
| Too short | release < tap threshold, or while preparing | tooltip "按住说话"; nothing sent; cancel haptic (threshold: Q4, 300 ms) |
| Preparing | touch down on the bar | in the touch's own frame (probe: drawn 11 ms median after the handler, 4-20 ms): the bar under the finger is pressed (scale 0.97, darker fill, label 按住说话) and the sheet pops up in a preparing state: 「准备中…」 instead of the timer, dimmed flat placeholder bars breathing (opacity 0.25-0.6, 1.1 s period; static at 0.43 with Reduce Motion), hint 「麦克风就绪后会轻震一下」. No haptic. Lasts until the input starts (about 0.25 s on the speaker route, 17 Pro Max; instant while ambient is on) |
| Recording | the microphone input starts capturing | 0.12 s cross-fade to live: timer starts, waveform follows the mic, the bar turns teal 「松开发送」, hint 「松开发送 · 手指移出按钮取消」; the light haptic fires in the same view update as the switch (probe: within 1-9 ms of the live sheet being drawn). Nav subtitle 在听你说 |
| Cancel armed | finger leaves the bar's frame (any direction), preparing or recording | middle of the sheet shows the cancel target: × in an attention circle and "松手取消"; hint "移回按钮继续录音"; the bar greys; haptic tick |
| Resumed | finger moves back onto the bar | timer and waveform return, bar teal again "松开发送"; haptic tick |
| Cancelled | release off the bar | sheet drops, nothing sent, audio discarded |
| Sending | release on the bar | sheet drops; my voice bubble appears dimmed with waveform + spinner, meta "正在识别…" |
| Accepted | `/api/messages` 202 | meta stays "正在识别…"; no text yet |
| Recognised | `message cleaned` (or the row with the message id) | bubble shows the text the brain receives, never the raw transcript; working bubble starts at `turn received` |
| Didn't catch | `message failed(empty_transcript)` | bubble removed, centre note "没听清，再说一次" |
| ASR failed | `message failed(asr_failed)` | failed bubble: "识别出错 · 轻点重试" |
| Voice unavailable | 503 / `message failed(perception_unavailable)` | failed bubble: "语音服务暂不可用 · 轻点重试" |
| Not sent | network / 5xx after retries | failed bubble: "没发出去 · 轻点重试"; packets kept, retry reuses the same `Idempotency-Key` |

- Touch delivery: the bar handles raw UIKit touches (`touchesBegan`), not a SwiftUI drag
  gesture, and the conversation defers the bottom-edge system gesture
  (`defersSystemGestures(on: .bottom)`), because the bar sits just above the home indicator,
  where iOS otherwise holds a touch back until it has ruled out a home swipe. Cost: going home
  from the conversation takes a second swipe (the first shows the indicator). `hold_timing`
  logs `touch_age_ms`: the touch's hardware timestamp to the handler.
- VoiceOver: the mic becomes a toggle (double-tap start, double-tap send, escape cancels); Magic
  Tap (two-finger double tap) does the same from anywhere in the conversation.
- Retries are idempotent by `Idempotency-Key` (`docs/ble-protocol.md` §2).
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

- Ambient view (full screen, opened when ambient turns on): the live mark, phase title (在听 / 在想 / 在查 / 正在说), while a tool runs the current step line
  (§4.4, subheadline, two lines at most), sub-line ("说话就能打断它" while speaking), live
  caption card of the current answer, last heard line, and four controls: 静音, 别说了 (only enabled
  while speaking), 对话, 关闭. 对话 lays the conversation over the room (read only, no composer):
  the mark moves to the top, the thread takes the middle, the controls shrink; it reads 隐藏对话 while
  shown and is remembered across openings. ⌄ minimises to the pill.
- Ambient pill (minimised, in the conversation): teal pill under the nav bar with the level meter,
  phase, route ("扬声器 · 回声消除已开"), 别说了 and ⏻. Tap expands to the ambient view.

| Ambient sub-state | Source | Display |
|---|---|---|
| Starting | engine starting, socket opening | "正在打开麦克风…" |
| Listening | `role: master`, `meta.state: listening`, uplink live | 在听, the halo follows RMS |
| Heard | `transcript` frame | heard line updates |
| Thinking / tool | `turn` frames | 在想 / 在查, step line below (§4.4) |
| Speaking | local playback of a `c-` speech | 正在说, caption grows with `duoduo_said` |
| Filler | local playback of an `s` speech | 正在说, no caption |
| 静音 | user tapped 静音 | 在听; "已静音：还在听，回复只显示在屏幕上" |
| Seat taken | `role: peer` (another edge in the same room) | "另一台设备在听" + 在这台手机上听 (re-hello) |
| Deaf | `meta.state: unowned` while on, or mic revoked | `unavailable` mark, "听不到了" + 重新打开 |
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
Sound: 播放语音回复 (default off; with ambient mode off, the `/live` `audio` switch, §7.1), 保持屏幕常亮 (default off: while
the app is in front the screen does not lock, so the phone can stand out as a speaker), 连着
AirPods 时用 手机麦克风 (default) / AirPods 麦克风 (§4.6.1).
Tailscale row: state, node name, IP, 退出登录 (confirm). Diagnostics: export logs (app log +
tsnet log + Passport log as one share sheet), version.

### 4.10 Errors (copy)

| Condition | Copy | Action |
|---|---|---|
| Upload / message network failure | 没发出去 · 轻点重试 | voice upload: retried with the same key until its deadline; typed: network errors resent on reconnect, a 5xx or other status marked failed with no automatic retry; the user's tap resends with the same key |
| `message failed(empty_transcript)` | 没听清，再说一次 | — |
| `message failed(asr_failed)` | 识别出错 · 轻点重试 | retry |
| 503 / `message failed(perception_unavailable)` | 语音服务暂不可用 | retry later |
| Read aloud failed | see §7.7 | — |
| `message failed(brain_unreachable)` | 没送到多多 (under the row) | resend as a new message |
| 413 | 文件太大 | remove chip |
| Mic permission denied | 需要麦克风权限才能说话 | 去设置 |
| Bluetooth off / denied | 蓝牙已关闭，Passport 连不上 | 去设置 |
| Protocol mismatch | 版本不匹配 | update |
| 410 `update_required` | banner 多多随身需要更新 | 更新: opens the TestFlight sign-up form the README links |
| `ready.api` absent or below 1, or 404 from `/api/messages` | banner 家里的 ambient 需要升级 · names the Upgrading section of ambient's `docs/deploy.md` | upgrade the channel |
| `cerebellum_halt` reason `protocol` | 小脑与 channel 版本不一致，需要两端同时升级 (settings status, voice notice) | upgrade both |

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
- Reduce Motion: a still mark that keeps its halo colour; Reduce Transparency: opaque bars.

## 6. Endpoint map

All requests go over tsnet (`Tailnet.request` / native WS), never through the loopback proxy, which
is removed with the web view.

| Feature | Endpoint / frame | Notes |
|---|---|---|
| Health check (onboarding, Passport `APP_STATE`) | `GET /healthz` | `{ok, rooms}` |
| Room state | `GET /api/state?room=` | `daemon_ok`, `cerebellum_ok`, `capture.owner`, `controls`, `room_name`, `date`, `limits`; no rows |
| Older history | `GET /api/imlog?room=&date=YYYY-MM-DD` | one day per request, walked backwards while the user scrolls up; also the first load for a room without a cursor |
| Rows without a socket | `GET /api/imlog?room=&since=<seq>` | `{entries, seq}`: Background App Refresh, BLE wake |
| Live updates (always) | WS `/live?room=&since=<seq>&audio=0\|1` | `meta`, `audio_params` (audio on only), the rows after `since`, `ready{seq, turn, messages, api}`, then `row`, `message`, `turn`, `duoduo_said`, `answer_final`, `transcript`, `playback`, `tts_interrupted`, `cerebellum`, `understood`/`wake_ignored`/`ack_silenced` |
| Typed text | `POST /api/messages?room=` JSON `{text, attachments?}`, `Idempotency-Key` | 202 `{message_id, at}` |
| Attachment upload | `POST /api/upload?room=&name=` (raw body, `Content-Type` = mime) | 200 `{name, mime, path, sha256}` → goes into the message's `attachments` |
| Attachment display | `GET /api/attachment?room=&sha256=&mime=&name=` | immutable, cache forever |
| Hold-to-talk and Passport voice notes | `POST /api/messages?room=` (`application/vnd.ambient.opus-packets`, `Idempotency-Key`, `X-Voice-Source: phone\|passport`) | 202 `{message_id, at}`; then `message cleaned` / `failed` on `/live` |
| Ambient edge | `hello{edge:"client", aec}` on the same `/live` socket | section 7 |
| Ambient mute | edge frame `mute{on}` | `on` is the room's capture switch: `on:true` = mic on, `on:false` = muted |
| Ambient "别说了" | edge frame `hush` + local stop | |
| Playback receipts | edge frame `played{speech_id, ms}` | watermark, not delta |
| Press stops playback | edge frame `interrupted{speech_id}` | ambient on only: per speech cut or dropped during a press (section 7.4) |
| Read aloud | `POST /api/speech?room=` JSON `{text}` | 200 streams `application/vnd.ambient.opus-packets` (the voice message framing); 413 `body_too_large`, 422 `nothing_to_speak`, 502 `synthesis_failed`, 503 `cerebellum_unavailable`; a body cut after the first packet is a reset (section 7.7) |

Gaps found in the current channel (branch `feature/pocket-voice-note`):
- No `turn idle` / end-of-turn-without-answer frame (Q7).
- Upload size limit is not exposed before upload (Q8).
- Scroll-back uses `/api/imlog` per day, which has no cursor inside a day (acceptable: one day is
  one file).

## 7. Native ambient edge

### 7.1 Socket

```
/live?room=&since=<seq>&audio=0|1   no hello while ambient is off   always on while foreground, a press or
                                    hello while ambient is on        reply is pending, or ambient runs
```

- `audio` is the phone's mouth switch, fixed for the connection's life: `1` while ambient
  mode runs, or while the 播放语音回复 setting is on and the app is in front, else `0`. A change
  (the setting, ambient mode, the app entering or leaving the background) replaces the connection from the
  cursor; `PocketEngine` treats a connection opened with the other switch as stale. With ambient mode
  off, turning the setting off also stops local playback at once.
- Live mode: ambient on, the phone holds the capture seat; the room's speech comes here only, paced
  by this phone's `played`. Message mode: ambient off (no capture owner in the room); every
  audio-on surface receives the room's speech as fast as it is synthesized, the channel counts a
  speech finished when its synthesis completes, and it takes no report from any surface. When a
  room device holds the seat, it plays and the phone shows text.

- One socket. Ambient on: `hello` on the open socket. Ambient off: close it and open a new
  one from the stored cursor without `hello`, because a socket cannot un-hello; closing is how
  the seat is released at once (`EdgeHub.remove`). The cursor replay means the close loses no rows.
- `AmbientController` owns the socket: audio-plane frames (`audio_params`, `speech`, binary,
  `stop_audio`, `meta{role,state,conn}`) go to the edge state machine, every text frame to
  `PocketEngine`, which keeps the socket open while it is wanted and reopens it.
- `Bridge/tsbridge` has one WS with text and binary both ways (one Opus packet per binary frame,
  ≤ 1 MiB per message), ping and an immediate close.

### 7.2 Handshake (same rules as the web edge, `capture.js` / `transport.js`)

1. Open the socket (or use the open one); receive `meta{conn}`.
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
2. A `speech` declaration stops nothing: it does not clear the player, so audio already received
   plays first and speeches play in the order they were declared (in message mode several arrive
   faster than they play). It resets the decoder, since a new speech is a new Opus stream; packets
   are decoded as they arrive, so the reset loses no audio.
3. Decode with `OpusVoiceDecoder` (16 kHz), schedule buffers on the player node.
4. Ambient on only: report `played{speech_id, ms}` as a cumulative watermark from buffer completion
   callbacks (not from scheduling), every 250 ms (the web cadence) and once at drain. The channel
   leaves SPEAKING only when `played ≥ audio_ms`. With ambient off nothing is reported.
5. `stop_audio{speech_id?, reason}` naming the current speech, or naming none, clears every
   buffered speech whatever its id, and resets the decoder; one naming another speech is stale and
   ignored. Fillers (`s…`) finish. No `played` after a stop for that id.
6. 别说了 (local hush): stop everything locally, including fillers and a read, then send `hush`.
7. A press (Passport, or hold-to-talk where it is allowed) stops local playback at once, fillers
   too. With ambient on it sends `interrupted{speech_id}` for the speech that was playing; whether
   earlier answers are superseded is decided when the press's message arrives. While the press is
   held nothing plays: each `speech` that arrives is dropped (its audio discarded) and, with
   ambient on, reported with the same frame, because the channel waits for playback reports. With
   ambient off the drop is local and silent. The press is app-local: no frame announces it. The
   text stays in the thread.
8. Ambient off: playback runs on a playback-only engine (no input node, so no microphone) in a
   `.playback` / `.spokenAudio` session with `.duckOthers`, started at the first scheduled block
   and stopped, with the session deactivated, when every scheduled block has played or when it
   fails to start. A hold or ambient mode replaces it with their own engine; any engine stops when
   its last block has played and no hold or ambient mode holds it.

Barge-in needs nothing extra on the phone: with echo cancellation the user's voice reaches the
cerebellum, which decides and the channel sends `stop_audio{reason:"barge_in"}`.

### 7.5 Interaction with hold-to-talk and the Passport

- Hold-to-talk while ambient is on: off; the composer offers text only (§4.5). The room already
  hears the phone, and a press would only duplicate it.
- Passport press while ambient is on: the phone mic hears the user too; send `mute{on:false}`
  between `PRESS_START` and `PRESS_END` (room mic off; the uplink keeps flowing, since the seat
  lease would expire in a long press otherwise), so the same speech does not enter the brain twice
  (voice note + room judge). Q12. The press also stops playback (§7.4 item 7).
- 静音 in the ambient view silences the phone for this ambient session: new speech is decoded but
  not played, and each block is reported `played` at once, so the channel's speech ends without
  waiting and room talk cannot barge in on audio nobody hears; blocks queued before the tap finish
  at zero volume. The room still hears. The next ambient session starts audible. In
  ambient mode the audio session is in voice-chat mode, whose call volume cannot reach zero with
  the volume buttons, so this is the only way to keep the phone quiet while it listens. To stop
  the room hearing, the user turns ambient mode off.

### 7.6 Lifecycle and background

- Foreground: as above.
- App leaves the foreground: depends on Q3. With only `bluetooth-central`, iOS
  suspends capture; the app closes the seated socket on `scenePhase == .background` so the seat is
  released at once and answers become text (`unspoken` rows). On return it does not reopen ambient
  automatically unless Q3 says so.
- With ambient off nothing plays in the background: leaving the front asks for `audio=0` (the
  connection is replaced, or closed when nothing needs it) and stops a read. 保持屏幕常亮 keeps the
  screen on while the app is in front (`isIdleTimerDisabled`), for a phone standing out as a
  speaker.
- Interruptions (call, Siri, alarm): stop capture, close the socket (it reopens without `hello`),
  show 已暂停; on `.ended` with `.shouldResume` restart capture and re-hello.
- Thermal state ≥ serious: show a note; no automatic shutdown in v1.
- Answers for the Passport (no APNs): every answer the app receives is
  forwarded as REPLY, with or without a pending press: live on `/live` (foreground, press or reply
  wait, ambient), and as rows above the cursor (`GET /api/imlog?since=`) when the Passport link
  comes up (BLE wake) and from Background App Refresh (`BGAppRefreshTask`
  `dev.openduo.pocket.refresh`, scheduled on every move to the background with no earliest time;
  iOS decides when). Details in `docs/ble-protocol.md`.
- All per-frame work is O(append); SwiftUI updates only while active (repository rule).

### 7.7 Read aloud

- Long press on a 多多 bubble → 朗读: `POST /api/speech` with the text the bubble shows (the full
  text of a truncated row). The channel strips the markdown, synthesizes it and streams the
  packets back; the app plays them as they arrive. Nothing is stored; every read synthesizes again.
- A read stops the reply that plays or is declared; with ambient on that reply is reported
  `interrupted`, as a press reports it. Chunks of a stopped read are dropped, and a read cancelled
  before its request starts is never sent. A press,
  别说了, or a new `speech` declaration stops the read (the live exchange goes first). It is not
  stopped by a reconnect or by `stop_audio`, which concern the room's speech.
- With ambient off it plays on the playback-only engine; leaving the front stops it.
- The request has no deadline: the tsnet bring-up is bounded by `connectTimeout`, and the stream
  ends when it completes, breaks, or is cancelled by one of the stops above.
- Failures (toast): 422 这条没有能读的文字, 413 这条太长，读不了, 502 语音合成失败, 503 语音服务暂不可用,
  no response 连不上多多, a body cut after audio started 朗读中断了.

### 7.8 Backlog: playback with ambient off

The playback-only engine starts at the first block and stops when the queue empties, so a stall
inside a streamed reply restarts it (a short gap; other audio unducks and ducks again). Two
alternatives are kept for later:
- keep the engine until the channel's `playback` done event, fewer restarts at the cost of tying
  the engine's life to a channel event;
- mix with other audio without ducking and keep the engine while the app is in front with the
  switch on, no restarts, but replies compete with music.

## 8. Offline cache and history

- Store: one JSON file per room per day (`imlog-YYYY-MM-DD`), plus the room's cursor: the `seq`
  of the newest row held, written after the rows it names. Rows arrive once, above the cursor:
  replayed on connect (`/live?since=`), live as `row`, or from `GET /api/imlog?since=`; each is
  appended to its day. A room without a cursor takes `ready.seq` and loads its days by date; a
  fetched day replaces its file whole. Nothing is merged locally beyond pending rows.
- Local pending rows (unsent text, voice notes, uploads) live in a separate queue file, one
  message each under a fixed key, and are shown until the row whose `utt_id` is that key arrives.
  After a replay, an accepted message that `ready` neither lists nor logged is shown as failed.
- Launch shows the cache instantly; the network result replaces it without moving the scroll
  position.
- Retention: Q13.

## 9. Code structure

```
App/
├── Engine/   PocketEngine (Passport, voice notes) · ConversationStore · AmbientController ·
│             AudioIO · HoldTiming
├── Device/   PassportLink (BLE central)
├── Net/      Tailnet (tsnet, the /live socket) · ChannelClient (typed calls for section 6)
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
| Q11 | Ambient socket model | a) separate edge socket · b) one socket: hello when on, reconnect without hello when off (section 7.1) | a) clean seat release, display path never interrupted, needs a second WS in tsbridge · b) one WS; the reconnect resumes from the row cursor, so a toggle loses no rows | decided: b |
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
