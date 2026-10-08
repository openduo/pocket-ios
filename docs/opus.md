# Opus on iOS

Choice: **upstream libopus 1.6.1** from the xiph.org release tarball, SHA-256 pinned, built by
`scripts/build-opus.sh` into a static `Opus.xcframework` (iOS device, iOS simulator, macOS;
arm64). The Swift wrapper is `PocketOpus`; a small C shim (`COpusShim`) exposes
`opus_encoder_ctl`, which Swift cannot call because it is variadic.

Why not a wrapper package: the Swift wrappers around libopus vendor a fixed copy of the C sources
and lag upstream releases; the code the app needs from them is a few lines. Building the
upstream release keeps one maintained source (xiph) and one checksum to review.

Build flags: static, `OPUS_PRESUME_NEON` (all targets are arm64), DRED / OSCE / deep PLC off
(`docs/ble-protocol.md` §1 fixes plain Opus with FEC off; the neural extensions add model weights).
License: BSD-3-Clause, copied into the xcframework as `COPYING`.

Apple's built-in Opus encoder (`AVAudioConverter`) was not used: it does not expose complexity,
VBR, DTX or FEC, which `docs/ble-protocol.md` §1 fixes.
