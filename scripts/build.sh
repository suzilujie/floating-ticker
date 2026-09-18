#!/usr/bin/env bash
# ============================================================
# build.sh - compile unsigned ipa on macOS (same as GitHub CI)
#
# Usage:
#   ./scripts/build.sh
#
# Requires macOS + Xcode. Produces FloatingTicker-unsigned.ipa
# at the repo root. No code signing is performed here; signing
# happens later on Windows via Sideloadly.
# ============================================================
set -e
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[build] installing xcodegen..."
  brew install xcodegen
fi

echo "[build] generating project..."
xcodegen generate

echo "[build] compiling (unsigned, arm64)..."
xcodebuild build \
  -project FloatingTicker.xcodeproj \
  -scheme FloatingTicker \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CONFIGURATION_BUILD_DIR="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

echo "[build] packaging ipa..."
rm -rf Payload
mkdir -p Payload
cp -R build/FloatingTicker.app Payload/
zip -qr FloatingTicker-unsigned.ipa Payload
ls -lh FloatingTicker-unsigned.ipa
echo "[build] done: FloatingTicker-unsigned.ipa"
