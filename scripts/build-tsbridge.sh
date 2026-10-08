#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Binds Bridge/tsbridge (tsnet, native requests, display and edge sockets) into
# Vendor/Tsbridge.xcframework with gomobile. Needs Go and gomobile/gobind in
# PATH or ~/go/bin. GOPROXY may be overridden for the local network.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$PATH:$HOME/go/bin"
OUT="$ROOT/Vendor/Tsbridge.xcframework"
mkdir -p "$ROOT/Vendor"
rm -rf "$OUT"
cd "$ROOT/Bridge/tsbridge"
gomobile bind -target ios,iossimulator -iosversion 17.0 -o "$OUT" .
echo "built $OUT"
