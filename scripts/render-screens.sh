#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Development tool. Screenshots every -PocketDemo fixture on a connected, unlocked iPhone that
# has a Debug build installed, in light and dark.
#   DEVICE_UDID=<udid> scripts/render-screens.sh [out-dir]   (default build/screens)
# BUNDLE_ID overrides the app id (default dev.openduo.pocket). SETTLE is the wait in seconds
# between launch and capture (default 3): fixtures with timed steps need it. LAUNCH_ARGS adds
# launch arguments, e.g. LAUNCH_ARGS='-AppleLanguages (en) -AppleLocale en_US' for English.
set -eu
: "${DEVICE_UDID:?set DEVICE_UDID}"
OUT=${1:-build/screens}
APP_ID=${BUNDLE_ID:-dev.openduo.pocket}
WAIT=${SETTLE:-3}
SCREENS="empty chat-working chat-done voice-states composer-voice composer-text hold-preparing
hold-record hold-cancel duoduo-files attachments ambient-call ambient-chat ambient-tool
passport-sheet passport-pair settings onboard-tailnet onboard-connect offline"
for theme in light dark; do
  mkdir -p "$OUT/$theme"
  for s in $SCREENS; do
    xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$APP_ID" \
      -- -PocketDemo "$s" -ui.appearance "$theme" ${LAUNCH_ARGS:-} >/dev/null
    sleep "$WAIT"
    xcrun devicectl device capture screenshot --device "$DEVICE_UDID" --destination "$OUT/$theme/$s.png" >/dev/null
    echo "$OUT/$theme/$s.png"
  done
done
