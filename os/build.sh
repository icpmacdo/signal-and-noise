#!/bin/sh
# Build "Signal & Noise OS.app" into os/build/. A real .app bundle is needed so macOS can grant it
# Screen Recording permission (a bare binary run from a terminal would borrow the terminal's).
# Signed with your Apple Development identity when there is one, so the permission survives
# rebuilds (macOS ties it to the signature; an ad-hoc signature changes every build). Override
# with SIGN_ID=<identity hash>, or SIGN_ID=- for ad-hoc.
set -e
cd "$(dirname "$0")"
swift build -c release --product SignalNoiseOS
APP="build/Signal & Noise OS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SignalNoiseOS "$APP/Contents/MacOS/SignalNoiseOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Signal &amp; Noise OS</string>
  <key>CFBundleIdentifier</key><string>com.icpmacdo.signal-and-noise.os</string>
  <key>CFBundleExecutable</key><string>SignalNoiseOS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep 'Apple Development' | grep -v REVOKED | head -1 | awk '{print $2}')}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "signed with: ${SIGN_ID:--} ($( [ "${SIGN_ID:--}" = - ] && echo ad-hoc || echo identity))"
echo "built: $(pwd)/$APP"
