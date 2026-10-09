# Constants and their basis

Fixed values live in `PocketConstants`; operational values in `PocketTuning` (overridable from
UserDefaults keys `tuning.<name>`, seconds).

"Decision Qn" and "design §n" refer to `docs/design/native-app.md`. "Measured" values come from
probes on an iPhone XS Max and the Passport during development.

| Name | Value | Kind | Basis |
|---|---|---|---|
| `protoMajor` / `protoMinor` | 1 / 2 | fixed | `docs/ble-protocol.md` §7; minor 1 adds WORK, minor 2 adds the APP_STATE language byte |
| PDU header | 4 bytes | fixed | `docs/ble-protocol.md` §6 |
| Fragment payload | ATT value − 4 | derived at runtime | phone: `maximumWriteValueLength(.withoutResponse)`; 512-byte updates measured on an iPhone XS Max |
| `maxMessageBytes` | 4096 | fixed (`docs/ble-protocol.md` §6) | the Passport keeps one reply; its measured minimum free heap is 26.9 KB, so 4 KiB is ~15 %. ≈1,300 CJK chars. Largest device message is one Opus packet (RFC 6716 max 1,275 B) + 4 |
| Audio | 16 kHz mono, 20 ms (320 samples), complexity 0, VBR, DTX off, FEC off | fixed | `docs/ble-protocol.md` §1 |
| Opus bitrate | libopus automatic | — | not set by `docs/ble-protocol.md` §1 |
| Opus packet buffer | 1,275 bytes | fixed | RFC 6716 maximum packet |
| Opus application / signal | `OPUS_APPLICATION_VOIP` / `OPUS_SIGNAL_VOICE` | fixed, **no data** | input is speech only |
| Opus decode buffer | 120 ms of samples | fixed | RFC 6716 longest frame |
| `catchUpWindowRows` | 80 | fixed | channel `/api/state` returns `imlog.slice(-80)`; no older answer can come back through catch-up |
| Reply id floor | current Unix time, seconds | derived | unique ids on a Passport across app reinstalls; INFO carries no stored id to seed from; u32 seconds last until 2106 |
| `noReplyID` | 0 | fixed | REPLY_DONE meaning "stopped waiting" (`docs/ble-protocol.md` §7); tracker never emits 0 |
| Reply wait limit | none | — | `docs/ble-protocol.md` §9: the wait ends on the answer, `turn idle` or a display socket that cannot be restored; a brain turn can take minutes (168 s observed) |
| `uploadDeadline` | 25 s | tuning | iOS background task ≈30 s (Apple docs; `backgroundTimeRemaining` was unreadable right after a wake); margin to send RESULT |
| `uploadBackoffInitial` / `Max` | 0.5 s doubling to 4 s | tuning, **no data** | expected failure is a dead pooled connection after suspension, fixed by an immediate fresh dial; backoff only spaces repeats of a real outage |
| Per-attempt timeout | remaining deadline | derived | no separate constant |
| Retry policy | transport errors, 503, other 5xx retried with the same `X-Voice-Id`; 200 / 422 / 502 asr_failed / 4xx final | fixed | `docs/ble-protocol.md` §2 idempotency |
| `connectTimeout` | 8 s | tuning | measured on an iPhone XS Max: wake → socket 180-260 ms, worst stall 2.1 s; a BLE event gives ≈10 s of background time |
| `pingTimeout` | 3 s | tuning | measured latency max 2.1 s (iPhone XS Max) |
| Keepalive interval | device side, 5 s, no cap (`docs/ble-protocol.md` §7) | device config | must stay below the ≈10 s background window a BLE notification grants, so the app stays awake while a reply is pending |
| Tap threshold (Passport) | none in the app | — | `docs/ble-protocol.md` §7: a press of any length is speech; the device owns its 300 ms threshold |
| `AppModel.holdMinimum` (phone hold-to-talk) | 300 ms | fixed, named | decision Q4 (design §4.6): the same threshold the Passport firmware applies; a shorter release shows 「按住说话」 and sends nothing |
| Max press length | none | — | memory is ~3 KB/s of Opus; presses longer than 15 s must work |
| UI refresh | 1 s, foreground only | display | no effect on link or uploads |
| Go HTTP transport timeouts | Go `DefaultTransport` defaults | inherited | only the dialer is replaced by tsnet |
| Display and edge socket read limit | 1 MiB | fixed (Go) | the channel's own WebSocket `maxPayload` (`1 << 20`) |
| Display socket close | immediate (`CloseNow`), no closing handshake | fixed | the socket being replaced has usually sat through a suspension; a graceful close waited on coder/websocket's 5 s timeouts for a peer that was gone |
| tsnet hostname | `duoduo-pocket` | fixed | node name shown in the tailnet admin console |
| tsnet status timeout | 2 s | fixed (Go), **no data** | an in-process local-API call; bounds a status read for the UI only |
| `ChannelSettings.defaultPort` / HTTPS default | 443 / on | default setting | `tailscale serve` publishes HTTPS on 443 |
| `TryChannel.stepDelay` | 0.9 s | display, **no data** | try-it mode only: spaces the scripted thinking and tool frames so the steps can be read; a real turn's timing comes from the brain |
| Image viewer max zoom | image pixels ÷ fitted screen pixels (≥ 1) | derived | one image pixel per screen pixel; further zoom shows no more detail |
| Quote length | none | — | `<user-quote>` carries the whole quoted message; the bubble draws three lines of it |

## Native app (design `docs/design/native-app.md`)

| Name | Value | Kind | Basis |
|---|---|---|---|
| `AmbientEdge.playedReportMs` | 250 ms | fixed | the web edge's `PLAYED_REPORT_MS`; the watermark is also flushed when the playback queue drains |
| `AmbientEdge.rate` | 16 kHz | fixed | `docs/ble-protocol.md` §1; `audio_params.rate` is a notification, a different rate stops ambient |
| `AmbientController.redialDelay` | 1 s | fixed | the web edge's reconnect pause (`transport.js`); each dial is bounded by `connectTimeout` |
| `PocketEngine.redialDelay` | 1 s | fixed | same cadence for the display socket while the app is visible or ambient runs; Q9 shows the offline banner after the first failed attempt, so no delay constant |
| Edge socket write timeout | 5 s | fixed (Go) | one frame on a live tailnet path takes milliseconds; worst measured stall 2.1 s (iPhone XS Max). Writes run on their own queue, so a stalled write never blocks capture |
| Tailscale logout timeout | 10 s | fixed (Go) | bounds the Settings action on a dead control plane; display only |
| `ConversationStore.historyScanDays` | 14 days | fixed, **no data** | days probed backwards per "load earlier" before showing 「N 天没有记录 · 继续找」; each probe is one small `GET /api/imlog` |
| Working bubble after a reconnect | restored by the next `turn thinking` | channel | the channel repeats `turn thinking` every 2 s while the brain works (`bridge.turn_thinking_interval_ms`); no app timer |
| History refresh on connect | newest cached day through today | derived | a fetched day replaces its file (server authority); no count constant |
| Cache retention | everything | — | decision Q13 |
| `ThreadBuilder.separatorGap` | 10 min | display | design §4.3 |
| `ThreadBuilder.heardRunVisible` | 3 rows | display | decision Q6: runs longer than 3 fold |
| `AppModel.refreshSeconds` | 1 s | display | device and tailnet rows, the ambient view's clock and the Tailscale login poll, while visible; one in-process status call per tick |
| `LevelTrail.interval` / `count` | 50 ms / 48 samples | display | meters sample the mic level only while visible and active; per audio frame the engine only updates one number |
| Meter attack/decay | ×6 gain, 0.82 / 0.18 | display | the web edge's meter (`capture.js`) |
| `Composer.photoJPEGQuality` | 0.9 | fixed, **no data** | HEIC and camera photos become JPEG because the channel renders only PNG/JPEG/GIF/WebP inline; 0.9 is visually lossless for photos |
| Attachment upload timeout | `uploadDeadline` (25 s) | reused tuning | a photo over a slow path needs longer than a control request |
| Upload size limit | `limits.upload_max_bytes` from `/api/state` | server | decision Q8; without the field (older channel) the app sends and maps 413 to 「文件太大」 |
| Thread image width | 220 pt, height 0.5–1.4 × width | display | |
| Toast duration | 2 s | display | |
| Text resend after a lost response | possible duplicate | — | `/api/inject` has no idempotency key (voice notes do: `X-Voice-Id`); a text whose response was lost to a transport error is queued and sent again |
| Hold cancel boundary | the hold button's own frame | derived | the finger outside the 按住说话 bar arms cancel; the recording sheet redraws the bar at that frame, so the boundary is the visible button. No distance constant |
| Composer mode default | hold-to-talk | fixed | product decision: voice first; the last chosen mode is stored under `composer.voice` |
| Outbound attachment fetch | one `channel.file.download` per file, no retry, no size bound | channel | a failed fetch keeps the name without `sha256` (disabled card); the file size is whatever the brain queued |
| `ToolLine.maxChars` | 34 characters | display | same as the Feishu channel's process card (`TOOL_LINE_MAX_CHARS`): widest tool line that never wrapped on its compact card. Counts grapheme clusters (a CJK character is one). The full input stays in the daemon |
| `ToolLine.summaryKeys` | `description`, `command`, `file_path`, `path`, `pattern`, `query`, `url`, `prompt`, `text` | fixed | same as the Feishu channel's `SUMMARY_KEYS`; `description` leads because Bash / Task carry a one-line statement beside the raw command |
| Working card height | phase row + current step row, one line each | display | as the Feishu channel's card: the panel stays collapsed while running. Earlier steps fold into 「+N 步」; no visible-step count constant |
| Opened step list | every step, uncapped | display | the full step list is kept, as in the Feishu channel; the thread scrolls |
| Ambient view step line | 1 line | display | the working card's current step line, one line as on the card; already cut to `ToolLine.maxChars`, so the view only truncates at accessibility text sizes |
| Hold-to-talk tap size | 1,024 frames requested, 4,800 delivered (100 ms at 48 kHz) | iOS | the tap's supported range starts at 100 ms; the request is not honoured below it; the start haptic therefore fires at engine start, not at the first block |
| Background App Refresh interval | none (`earliestBeginDate` nil) | iOS | the system decides when to run; one request is kept pending, re-submitted on each move to the background and each run |
| `BarLayout.sideGap` | 12 pt | display | space between the nav subtitle and a side item's content; the side items draw their glass capsule about 5 pt outside the content (iPhone 17 Pro Max, iOS 26) |
| Thermal note | `ProcessInfo.ThermalState.serious` | display | the state at which Apple asks apps to reduce work; ambient shows a note, no automatic shutdown |
| Answered-turn lookup | the 2 newest cached days | derived | a question before midnight answered after it |
