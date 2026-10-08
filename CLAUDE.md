# CLAUDE.md

This repository contains 多多随身 (DuoDuo Pocket), the iPhone client for an ambient room and the
phone side of the Passport accessory link.

## Layout

- `App/` — the SwiftUI app: conversation, composer, ambient mode (audio engine + edge socket),
  Passport BLE central, voice notes, reply tracking, settings and onboarding.
- `Packages/PocketKit/` — platform-independent code shared with the simulator and tested on the
  host: link PDU codec, voice-note body, upload with idempotent retry, reply tracker, Opus wrapper,
  conversation cache, outbox, turn state, thread rows, ambient edge state machine.
- `Bridge/tsbridge/` — Go package bound with gomobile: embedded tsnet node, native requests, the
  display socket and the ambient edge socket.
- `Tools/PassportSim/` — macOS stand-in for the Passport (device side of the link).
- `Tools/mock-channel/` — fake channel for the upload and reply path.
- `docs/` — link contract, constants and their basis, app design, Opus build, final app icon.

## Build and verify

```sh
scripts/build-opus.sh            # once: Packages/PocketKit/Vendor/Opus.xcframework
scripts/build-tsbridge.sh        # once per Go change: Vendor/Tsbridge.xcframework
(cd Packages/PocketKit && swift test)
(cd Bridge/tsbridge && go vet ./... && go test ./...)
scripts/build.sh                 # simulator build, unsigned
DEVICE_UDID=<udid> scripts/build.sh   # signed device build and install
CONFIGURATION=Release DEVICE_UDID=generic scripts/build.sh   # Release, no fixtures or probes
scripts/check-license.sh
```

Device signing reads `DEVELOPMENT_TEAM` (and optionally `POCKET_BUNDLE_ID`) from
`Config/Signing.local.xcconfig`, which is not tracked.

## Rules

- Every `swift`, `go`, `c`, `h`, `sh`, `py` and `xcconfig` file starts with the two-line SPDX header
  (`FSL-1.1-Apache-2.0`), after the shebang when there is one. `scripts/check-license.sh` checks it.
  Bundled third-party code is listed in `THIRD_PARTY_NOTICES.md`; update it with any new dependency.
- The app icon, the 多多 / DuoDuo and OpenDuo names and the mockups are brand assets outside the
  code licence (`NOTICE`); the avatar artwork follows the code licence.
- The channel host, the room name and tailnet names are entered in the app and stored in
  UserDefaults. Never put host names, tailnet addresses, room names, team IDs, device IDs,
  credentials, logs or recordings in tracked files.
- The BLE link follows the shared contract; `docs/ble-protocol.md` records this repository's
  reading of it. Change both ends together.
- No UI work while the app is in the background, and per-audio-frame work stays O(append): iOS
  kills a background app above 80 % CPU over 60 s.
- Every runtime constant has a stated basis in `docs/constants.md`. A value without data is a
  named, overridable setting, not a silent literal.
- Source comments and commit messages are English; user-facing Chinese strings stay Chinese.
- Debug fixtures and probes (`-PocketDemo`, `-PocketPlaybackProbe`, `-PocketHoldProbe`) stay inside
  `#if DEBUG`.
- Design intermediates (icon rounds, superseded mockups, screenshots) go to the gitignored
  `docs/design/archive/`; only final designs that docs reference are tracked.
