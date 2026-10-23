#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Binds Bridge/tsbridge (tsnet, native requests, the /live socket) into
# Vendor/Tsbridge.xcframework with gomobile. Needs Go and gomobile/gobind in
# PATH or ~/go/bin. GOPROXY may be overridden for the local network.
#
# Two Tailscale files are replaced at build time with the patched copies in
# Bridge/tailscale-patches/tailscale (see the README there). The
# build stops if the upstream files no longer match the ones the patch was made
# against, so a Tailscale upgrade cannot silently drop or misapply the patch.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$PATH:$HOME/go/bin"
OUT="$ROOT/Vendor/Tsbridge.xcframework"
PATCHES="$ROOT/Bridge/tailscale-patches/tailscale"
cd "$ROOT/Bridge/tsbridge"

go mod download tailscale.com
UPSTREAM=$(go list -m -f '{{.Dir}}' tailscale.com)
[ -n "$UPSTREAM" ] || { echo "tailscale.com module not found" >&2; exit 1; }
(cd "$UPSTREAM" && shasum -a 256 -c "$PATCHES/UPSTREAM.sha256" >/dev/null) || {
	echo "tailscale.com changed since the patch in $PATCHES was made: re-apply it" >&2
	exit 1
}
# Build a copy of this module whose go.mod replaces tailscale.com with a
# patched copy, so the repository's go.mod stays as it is. (gomobile's own
# dependency check ignores -modfile, hence a copy rather than a flag.)
WORK=$(mktemp -d -t tsbridge-build)
trap 'chmod -R u+w "$WORK"; rm -rf "$WORK"' EXIT
cp -R "$UPSTREAM" "$WORK/tailscale.com"
chmod -R u+w "$WORK/tailscale.com"
cp "$PATCHES/net/netmon/netmon.go" "$WORK/tailscale.com/net/netmon/netmon.go"
cp "$PATCHES/wgengine/magicsock/magicsock.go" "$WORK/tailscale.com/wgengine/magicsock/magicsock.go"
mkdir "$WORK/tsbridge"
cp go.mod go.sum *.go "$WORK/tsbridge/"
rm -f "$WORK"/tsbridge/*_test.go
cd "$WORK/tsbridge"
go mod edit -replace "tailscale.com=$WORK/tailscale.com"

mkdir -p "$ROOT/Vendor"
rm -rf "$OUT"
gomobile bind -target ios,iossimulator -iosversion 17.0 -o "$OUT" .
echo "built $OUT"
