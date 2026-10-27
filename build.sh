#!/bin/zsh
# Build a standalone macOS app; does not launch or play audio.
set -eu
cd "${0:A:h}"
APP="${1:-$PWD/SMC Sampler.app}"
mkdir -p "$APP/Contents/MacOS"
# The installer builds both architectures into a private staging directory.
# A normal local build retains the host architecture.
ARCHS="${ARCHS:-$(uname -m)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/smcsampler-build.XXXXXX")"
trap '/bin/rm -rf -- "$WORK"' EXIT
typeset -a BINARIES
for ARCH in ${=ARCHS}; do
  [[ "$ARCH" = arm64 || "$ARCH" = x86_64 ]] || { print -u2 'Unsupported architecture'; exit 1; }
  xcrun swiftc Sources/main.swift -target "$ARCH-apple-macosx13.0" -o "$WORK/$ARCH" -framework Cocoa -framework AVFoundation -framework CoreMIDI
  BINARIES+=("$WORK/$ARCH")
done
xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/SMCSampler"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SMCSampler</string>
<key>CFBundleIdentifier</key><string>life.azat.smcsampler</string>
<key>CFBundleName</key><string>SMC Sampler</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Подключение MIDI-контроллера SMC-Mixer.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
