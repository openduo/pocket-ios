#!/bin/sh
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0

# Builds upstream libopus (xiph.org release tarball, SHA-256 pinned) into
# Packages/PocketKit/Vendor/Opus.xcframework: static libraries for iOS
# devices, the iOS simulator and macOS (the Passport simulator and host
# tests). Why upstream and not a wrapper package: see docs/opus.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=1.6.1
SHA256=6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
URL="https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz"
WORK="$ROOT/.build-vendor/opus"
OUT="$ROOT/Packages/PocketKit/Vendor/Opus.xcframework"

mkdir -p "$WORK"
TARBALL="$WORK/opus-$VERSION.tar.gz"
if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
tar xzf "$TARBALL" -C "$WORK/src" --strip-components 1

# Neural extensions (DRED, OSCE, deep PLC) are off: docs/ble-protocol.md §1
# fixes plain Opus with FEC off, and they add model weights to the binary.
build_slice() { # name system sysroot
  name=$1 system=$2 sysroot=$3
  b="$WORK/build-$name"
  rm -rf "$b"
  if [ "$system" = iOS ]; then target="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0"
  else target="-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"; fi
  # shellcheck disable=SC2086
  cmake -S "$WORK/src" -B "$b" $target -DCMAKE_OSX_SYSROOT="$sysroot" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_PRESUME_NEON=ON -DOPUS_DRED=OFF -DOPUS_OSCE=OFF -DOPUS_DEEP_PLC=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
    -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
  cmake --build "$b" --config Release -j 8 >/dev/null
  # A static library plus headers, not a framework: Xcode embeds every framework from a
  # package binary target, and a static one becomes an empty stub in the app bundle.
  lib="$WORK/lib-$name"
  rm -rf "$lib" && mkdir -p "$lib/Headers/Opus"
  cp "$b/libopus.a" "$lib/libopus.a"
  # The single-stream API is all the app uses; the other headers stay out of the module.
  cp "$WORK/src/include/opus.h" "$WORK/src/include/opus_types.h" "$WORK/src/include/opus_defines.h" \
    "$lib/Headers/Opus/"
  # Inside Headers/Opus so clang finds it for `import Opus` and `#include <Opus/opus.h>`.
  printf 'module Opus {\n  umbrella header "opus.h"\n  export *\n}\n' \
    > "$lib/Headers/Opus/module.modulemap"
}

build_slice ios iOS iphoneos
build_slice sim iOS iphonesimulator
build_slice mac Darwin macosx

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$WORK/lib-ios/libopus.a" -headers "$WORK/lib-ios/Headers" \
  -library "$WORK/lib-sim/libopus.a" -headers "$WORK/lib-sim/Headers" \
  -library "$WORK/lib-mac/libopus.a" -headers "$WORK/lib-mac/Headers" \
  -output "$OUT" >/dev/null
cp "$WORK/src/COPYING" "$OUT/COPYING"
echo "built $OUT (libopus $VERSION)"
