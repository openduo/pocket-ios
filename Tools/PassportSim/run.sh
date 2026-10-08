#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Development tool. Builds PassportSim, wraps it in a minimal .app (so macOS asks for and remembers the Bluetooth
# permission for the simulator itself), and launches it. Drive it through the control FIFO:
#   echo 'press 明天早上八点提醒我开会' > logs/control
#   echo quit > logs/control
# Arguments are passed through (for example --insecure, --proto-major 2).
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=.build/PassportSim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" logs
cp .build/release/PassportSim "$APP/Contents/MacOS/"
cp Sources/PassportSim/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
STAMP=$(date +%Y%m%d-%H%M%S)
open -n "$APP" --stdout "$PWD/logs/sim-$STAMP.out" --stderr "$PWD/logs/sim-$STAMP.out" \
  --args --log "$PWD/logs/sim-$STAMP.jsonl" --control "$PWD/logs/control" "$@"
sleep 2
pgrep -n -f "$APP/Contents/MacOS/PassportSim" > logs/sim.pid || true
echo "pid $(cat logs/sim.pid); output logs/sim-$STAMP.out; events logs/sim-$STAMP.jsonl; control logs/control"
