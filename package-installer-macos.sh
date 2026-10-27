#!/bin/bash
# Build a universal Installer package without installing or launching the app.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION='0.4.1'
OUT_DIR="$ROOT/generated"
OUT="$OUT_DIR/SMC-Sampler-$VERSION-macOS-universal.pkg"
fail() { echo "package-installer: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'macOS is required'
mkdir -p "$OUT_DIR"
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "refusing to overwrite: $OUT"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${APP_SIGN_IDENTITY:-}" ] && [ -n "${INSTALLER_SIGN_IDENTITY:-}" ] || fail 'notarization requires both Developer ID identities'
fi
if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
  [ -n "${APP_SIGN_IDENTITY:-}" ] || fail 'a signed installer requires a signed application'
fi
WORK="$(mktemp -d "$OUT_DIR/.smcsampler-pkg.XXXXXX")"
trap '/bin/rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT TERM
PAYLOAD="$WORK/root"
APP="$PAYLOAD/SMC Sampler.app"
mkdir -p "$PAYLOAD"
ARCHS='arm64 x86_64' "$ROOT/build.sh" "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict --all-architectures "$APP"
ARCH_LIST="$(xcrun lipo -archs "$APP/Contents/MacOS/SMCSampler")"
for ARCH in arm64 x86_64; do
  [[ " $ARCH_LIST " = *" $ARCH "* ]] || fail "missing architecture: $ARCH"
done
"$APP/Contents/MacOS/SMCSampler" --self-test

# Disable relocation: installation always targets /Applications, even if a
# previous bundle with this identifier exists elsewhere. Replace the bundle
# as a unit so obsolete files from earlier versions cannot remain inside it.
cat > "$WORK/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>RootRelativeBundlePath</key><string>SMC Sampler.app</string>
  <key>BundleIsRelocatable</key><false/>
  <key>BundleIsVersionChecked</key><true/>
  <key>BundleHasStrictIdentifier</key><true/>
  <key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
pkgbuild --root "$PAYLOAD" --component-plist "$WORK/components.plist" \
  --identifier life.azat.smcsampler.installer --version "$VERSION" \
  --install-location /Applications --ownership recommended "$WORK/app.pkg"

cat > "$WORK/Distribution" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>SMC Sampler</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" title="SMC Sampler" visible="false"><pkg-ref id="life.azat.smcsampler.installer"/></choice>
  <pkg-ref id="life.azat.smcsampler.installer" version="0.4.1" onConclusion="none">app.pkg</pkg-ref>
</installer-gui-script>
XML
SIGN_ARGS=()
if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
fi
productbuild --distribution "$WORK/Distribution" --package-path "$WORK" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$WORK/installer.pkg"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$WORK/installer.pkg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORK/installer.pkg"
  xcrun stapler validate "$WORK/installer.pkg"
  spctl --assess --type install --verbose=2 "$WORK/installer.pkg"
fi
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "refusing to overwrite: $OUT"
mv -n "$WORK/installer.pkg" "$OUT"
[ ! -e "$WORK/installer.pkg" ] || fail 'could not place installer at output path'
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Created: $OUT"
if [ -z "${NOTARY_PROFILE:-}" ]; then
  echo 'Distribution without Apple Developer: app signed ad-hoc, package not notarized. Gatekeeper may require manual approval after download.'
fi
