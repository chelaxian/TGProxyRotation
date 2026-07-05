#!/usr/bin/env bash
# Build helper for TGProxyRotation.
#
# The project lives under a Windows path that (a) contains spaces and (b) is a
# DrvFs mount reporting mode 0777 — both break Theos/dpkg-deb directly. So this
# script copies the sources into a clean, spaceless, native-WSL directory, builds
# there, and copies the artifacts back into ./packages/.
#
# Run from WSL (Ubuntu):   bash build.sh
# From Windows git-bash:    wsl.exe -e bash -lc 'cd "$(pwd)"; bash build.sh'   (or just run in WSL)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HOME/tgproxy-build"
export THEOS="${THEOS:-$HOME/theos}"

VERSION="$(grep '^Version:' "$SRC_DIR/control" | awk '{print $2}')"
echo ">> Building TGProxyRotation $VERSION"
echo ">> src:   $SRC_DIR"
echo ">> build: $BUILD_DIR"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp "$SRC_DIR"/Tweak.x "$SRC_DIR"/Tweak.dylib.m "$SRC_DIR"/Logger.h "$SRC_DIR"/Logger.m \
   "$SRC_DIR"/Makefile "$SRC_DIR"/Makefile.dylib "$SRC_DIR"/control "$SRC_DIR"/TGProxyRotation.plist \
   "$BUILD_DIR"/
chmod 755 "$BUILD_DIR"

cd "$BUILD_DIR"

echo ">> [1/2] deb (Tweak.x, arm64 -> arm64e via .roothidepatch)"
make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

echo ">> [2/2] sideload dylib (Tweak.dylib.m)"
make -f Makefile.dylib clean >/dev/null 2>&1 || true
make -f Makefile.dylib FINALPACKAGE=1

DEB="$BUILD_DIR/packages/com.ratush.tgproxyrotation_${VERSION}_iphoneos-arm64e.deb"
DYLIB="$BUILD_DIR/.theos/obj/TGProxyRotation.dylib"

mkdir -p "$SRC_DIR/packages"
cp "$DEB" "$SRC_DIR/packages/"
cp "$DYLIB" "$SRC_DIR/packages/TGProxyRotation-${VERSION}.dylib"

echo ">> DONE. Artifacts copied to packages/:"
echo "   com.ratush.tgproxyrotation_${VERSION}_iphoneos-arm64e.deb"
echo "   TGProxyRotation-${VERSION}.dylib"
