# 多多随身 (DuoDuo Pocket)

iPhone client for one ambient room, and the phone side of the Passport push-to-talk accessory.

- A native SwiftUI conversation with 多多 for one room: text, photos and files, hold-to-talk,
  and an ambient mode in which the phone listens to the room and speaks the answers
  (`docs/design/native-app.md`). History comes from the channel and is cached for offline reading.
- The app reaches the channel over an embedded Tailscale node (tsnet, userspace); no VPN profile.
- The Passport (a FoloToy AI Passport running the `openduo/pocket-passport` firmware) streams
  Opus over BLE while its button is held; the app uploads one voice note per press, tells the
  Passport the transcript, and forwards the answer to its screen.
- Hold-to-talk in the app records with the phone microphone and uses the same voice-note path.

## Architecture

```
SwiftUI views ◀── AppModel (main actor; snapshots only while active)
                    ▲            ▲              ▲
ConversationStore ──┘  AmbientController ──┘   PocketEngine ──┘
 cache · outbox ·        edge socket ·          Passport link · voice notes ·
 turn state              VoiceIO (AVAudioEngine, AEC, Opus) · display socket · replies
        │                        │                          │
        └──────────── tsnet (Go, gomobile) ─────────────────┴──▶ channel host (tailnet, HTTPS)
                       /api/state · /api/imlog · /api/inject · /api/upload · /api/attachment
                       /api/voice · /live (display, no hello) · /live (edge, hello + Opus)
Passport ──BLE──▶ PassportLink ─▶ PocketEngine ─▶ RESULT / REPLY / REPLY_DONE / APP_STATE / WORK
```

- Everything dials out through tsnet; nothing listens on the phone.
- Two `/live` sockets: the display socket (conversation frames, Passport replies) and, only while
  ambient is on, the edge socket that holds the room's capture seat. Closing the edge socket
  releases the seat without touching the conversation.
- Background budget: per audio frame only O(append) work on audio queues; SwiftUI is updated only
  while the app is active, from coalesced snapshots.
- Background modes: `bluetooth-central` (state restoration relaunches the app for Passport
  traffic), `audio` (ambient mode keeps listening when locked, started and ended by the user) and
  `fetch` (Background App Refresh catches up answers for the Passport).

## Requirements

- Xcode with the iOS 17 SDK or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), CMake.
- Go and gomobile (`go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`).
- A channel host from [ambient](https://github.com/openduo/ambient) reachable on your tailnet.

## Setup

1. `scripts/build-opus.sh` and `scripts/build-tsbridge.sh`.
2. `Config/Signing.local.xcconfig` (gitignored) with `DEVELOPMENT_TEAM = <team>`. If your team
   cannot use the bundle id `dev.openduo.pocket`, set `POCKET_BUNDLE_ID = <your id>` there too.
3. `DEVICE_UDID=<udid> scripts/build.sh`. `CONFIGURATION=Release` builds without the Debug
   fixtures and probes.
4. First launch walks through Tailscale login, channel host + room (with a live check) and the
   Passport. Settings keep host, HTTPS/port and room in UserDefaults.
5. Debug builds show design fixtures with `-PocketDemo <screen>` (list in
   `docs/design/native-app.md` §11), e.g. `xcrun devicectl device process launch --device <udid>
   dev.openduo.pocket -- -PocketDemo chat-working -ui.appearance dark`.

## Testing without a Passport

- `Tools/PassportSim/run.sh` runs the device side of the link on a Mac (pairing, INFO, presses of
  synthesized speech in real time, KEEPALIVE until REPLY_DONE). Commands go to `logs/control`.
- `Tools/mock-channel` answers `/api/voice`, `/live` and `/api/state` with fake transcripts, for
  testing the upload/reply path without a channel.
- Use a phone that does not share an Apple ID with the Mac: Continuity holds its own LE link to
  the Mac and can block connects.

## Docs

- `docs/design/native-app.md` — product UI design and decisions.
- `docs/ble-protocol.md` — the Passport link and voice-note contract, as implemented.
- `docs/constants.md` — every constant with its basis.
- `docs/opus.md` — libopus build choice.
- `docs/design/icon/final/` — the app icon source.

## Security

See `SECURITY.md`. The app talks only to a channel on your own tailnet.

## License

The code, including the 多多 avatar artwork, is FSL-1.1-Apache-2.0 (see `LICENSE`). The app icon,
the 多多 / DuoDuo and OpenDuo names and the design mockups are OpenDuo brand assets with no open
licence; forks must replace them (see `NOTICE`). Bundled third-party code (libopus, Tailscale's
tsnet and its Go dependencies) keeps its own licences; see `THIRD_PARTY_NOTICES.md`.
