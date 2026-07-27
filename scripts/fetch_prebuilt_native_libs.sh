#!/usr/bin/env bash
#
# Fetch the prebuilt RustDesk native libraries from an official GitHub release
# and install them into flutter/android/app/src/main/jniLibs/<abi>/.
#
# This fork only changes Dart and Kotlin, so there is no reason to cross-compile
# the Rust core (which would need the Android NDK, vcpkg and cargo-ndk, and tens
# of GB of disk). Instead we reuse the librustdesk.so that upstream already
# built and shipped.
#
# The release version MUST match the checked-out source tree, because the
# flutter_rust_bridge FFI surface is generated from src/flutter_ffi.rs at that
# revision. A mismatch produces confusing crashes deep inside the bridge that
# look unrelated to whatever you were working on. To make that mistake hard,
# the default version is read from Cargo.toml rather than hardcoded.
#
# Usage:
#   scripts/fetch_prebuilt_native_libs.sh [--abi arm64-v8a] [--version 1.4.9] [--force]

set -euo pipefail

ABI="arm64-v8a"
VERSION=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi)     ABI="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Default to the version of the source tree we are sitting in.
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk '/^\[package\]/{p=1;next} /^\[/{p=0} p && /^version[[:space:]]*=/{gsub(/["[:space:]]/,"",$3); print $3; exit}' Cargo.toml)"
  # awk above splits on '=', so re-read robustly if that produced nothing.
  if [[ -z "$VERSION" ]]; then
    VERSION="$(grep -m1 -E '^version[[:space:]]*=' Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/')"
  fi
fi

# ABI -> the arch fragment used in official APK asset names.
case "$ABI" in
  arm64-v8a)   ASSET_ARCH="aarch64" ;;
  armeabi-v7a) ASSET_ARCH="armv7" ;;
  x86_64)      ASSET_ARCH="x86_64" ;;
  *) echo "unsupported ABI: $ABI" >&2; exit 2 ;;
esac

APK="rustdesk-${VERSION}-${ASSET_ARCH}-signed.apk"
URL="https://github.com/rustdesk/rustdesk/releases/download/${VERSION}/${APK}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/rustdesk-prebuilt"
DEST="flutter/android/app/src/main/jniLibs/${ABI}"

# Only these two. libapp.so and libflutter.so are also present in the release
# APK, but those are Flutter's own artifacts that our build regenerates --
# copying them into jniLibs would ship upstream's compiled Dart code alongside
# ours and silently mask every Dart change we make.
LIBS=(librustdesk.so libc++_shared.so)

if [[ $FORCE -eq 0 ]]; then
  missing=0
  for lib in "${LIBS[@]}"; do
    [[ -f "$DEST/$lib" ]] || missing=1
  done
  if [[ $missing -eq 0 ]]; then
    echo "native libs already present in $DEST (use --force to re-extract)"
    exit 0
  fi
fi

mkdir -p "$CACHE_DIR" "$DEST"

if [[ ! -f "$CACHE_DIR/$APK" ]]; then
  echo "downloading $APK"
  curl -fL --retry 3 --progress-bar -o "$CACHE_DIR/$APK.part" "$URL"
  mv "$CACHE_DIR/$APK.part" "$CACHE_DIR/$APK"
else
  echo "using cached $CACHE_DIR/$APK"
fi

for lib in "${LIBS[@]}"; do
  unzip -o -j "$CACHE_DIR/$APK" "lib/${ABI}/${lib}" -d "$DEST" >/dev/null
  if [[ ! -s "$DEST/$lib" ]]; then
    echo "error: failed to extract lib/${ABI}/${lib} from $APK" >&2
    exit 1
  fi
done

# Guard against grabbing the wrong ABI's APK: the ELF must not be host-native.
if command -v file >/dev/null; then
  echo
  for lib in "${LIBS[@]}"; do
    printf '  %s\n' "$(file -b "$DEST/$lib" | cut -c1-80)"
  done
fi

echo
echo "installed ${LIBS[*]} for $ABI from RustDesk $VERSION into $DEST"
