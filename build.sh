#!/bin/zsh
# Build a standalone macOS app; does not launch or play audio.
set -eu
cd "${0:A:h}"
mkdir -p 'SMC Sampler.app/Contents/MacOS'
xcrun swiftc Sources/main.swift -o 'SMC Sampler.app/Contents/MacOS/SMCSampler' -framework Cocoa -framework AVFoundation -framework CoreMIDI
cat > 'SMC Sampler.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SMCSampler</string>
<key>CFBundleIdentifier</key><string>life.azat.smcsampler</string>
<key>CFBundleName</key><string>SMC Sampler</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Подключение MIDI-контроллера SMC-Mixer.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - 'SMC Sampler.app'
