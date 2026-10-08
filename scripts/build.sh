#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Builds 多多随身 and, with a device id, installs it.
#   scripts/build.sh                          simulator build, unsigned
#   DEVICE_UDID=<udid> scripts/build.sh       build for that iPhone, sign, install
#   DEVICE_UDID=generic scripts/build.sh      signed build for any iPhone, no install
# CONFIGURATION=Release builds without the Debug fixtures and probes (default Debug).
# NO_INSTALL=1 skips the install.
# Prerequisites: scripts/build-opus.sh, scripts/build-tsbridge.sh, xcodegen, and for a device
# Config/Signing.local.xcconfig with DEVELOPMENT_TEAM.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIG=${CONFIGURATION:-Debug}
[ -d Vendor/Tsbridge.xcframework ] || { echo "missing Vendor/Tsbridge.xcframework: run scripts/build-tsbridge.sh" >&2; exit 1; }
[ -d Packages/PocketKit/Vendor/Opus.xcframework ] || { echo "missing Opus.xcframework: run scripts/build-opus.sh" >&2; exit 1; }
xcodegen generate --quiet
if [ -z "${DEVICE_UDID:-}" ]; then
  xcodebuild -project DuoduoPocket.xcodeproj -scheme DuoduoPocket -configuration "$CONFIG" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
  exit 0
fi
if [ "$DEVICE_UDID" = generic ]; then
  DEST='generic/platform=iOS'
else
  DEST="id=$DEVICE_UDID"
fi
xcodebuild -project DuoduoPocket.xcodeproj -scheme DuoduoPocket -configuration "$CONFIG" \
  -destination "$DEST" -derivedDataPath build -allowProvisioningUpdates build
APP="build/Build/Products/$CONFIG-iphoneos/DuoduoPocket.app"
if [ "${NO_INSTALL:-}" = 1 ] || [ "$DEVICE_UDID" = generic ]; then exit 0; fi
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"
