#!/bin/bash
# Build a drag-and-drop DMG for Apple Silicon macOS (system tools only, local ad-hoc signing).
# Does not launch the GUI or play audio; runs the binary's silent --self-test.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_NAME='SMC Sampler.app'
VOL_NAME='SMC Sampler'
OUT_DIR="$ROOT/generated"
OUT="$OUT_DIR/SMC Sampler.dmg"

fail() { echo "package-macos: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail 'macOS is required'
[ "$(uname -m)" = arm64 ] || fail 'Apple Silicon (arm64) is required'

mkdir -p "$OUT_DIR"
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "refusing to overwrite existing output: $OUT"

# 1. Build with the existing script (it cd's to its own directory).
"$ROOT/build.sh"

APP="$ROOT/$APP_NAME"
EXE="$APP/Contents/MacOS/SMCSampler"
[ -d "$APP" ] || fail "bundle missing: $APP"
[ -f "$APP/Contents/Info.plist" ] || fail 'Info.plist missing'
[ -x "$EXE" ] || fail "executable missing or not executable: $EXE"
file -b "$EXE" | grep -q 'Mach-O 64-bit executable arm64' || fail 'executable is not arm64'
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail 'Info.plist is invalid'
[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" = SMCSampler ] || fail 'CFBundleExecutable mismatch'
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = life.azat.smcsampler ] || fail 'CFBundleIdentifier mismatch'
codesign --verify --strict "$APP" || fail 'code signature verification failed'

# 2. Silent self-test.
LOG="$(mktemp "${TMPDIR:-/tmp}/smcsampler-selftest.XXXXXX")"
if ! "$EXE" --self-test >"$LOG" 2>&1; then
  cat "$LOG" >&2
  rm -f -- "$LOG"
  fail 'self-test failed'
fi
rm -f -- "$LOG"

# 3. Stage in a private temp dir; link the real app, copy nothing stale.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smcsampler-dmg.XXXXXX")"
# Only ever remove the exact mktemp dirs this script created (fresh empty dirs).
cleanup() {
  if [ -n "${STAGE:-}" ] && [ -d "$STAGE" ] && [ ! -L "$STAGE" ]; then /bin/rm -rf -- "$STAGE"; fi
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ] && [ ! -L "$WORK" ]; then /bin/rm -rf -- "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
[ -L "$STAGE/Applications" ] && [ "$(readlink "$STAGE/Applications")" = /Applications ] || fail 'Applications symlink invalid'
codesign --verify --strict "$STAGE/$APP_NAME" || fail 'staged copy signature invalid'

# 4. Compressed UDZO image in a private temp dir on the same volume as the output
#    (same filesystem, so the final move stays atomic). The path must not exist yet
#    and must end in .dmg, otherwise hdiutil appends .dmg to it.
WORK="$(mktemp -d "$OUT_DIR/.smcsampler-dmg.XXXXXX")"
TMP_DMG="$WORK/SMC Sampler.dmg"
[ ! -e "$TMP_DMG" ] && [ ! -L "$TMP_DMG" ] || fail 'temp DMG path already exists'
hdiutil create -quiet -format UDZO -fs HFS+ -volname "$VOL_NAME" -srcfolder "$STAGE" "$TMP_DMG"
[ -f "$TMP_DMG" ] && [ ! -L "$TMP_DMG" ] || fail 'hdiutil did not create the expected DMG path'
hdiutil verify -quiet "$TMP_DMG" || fail 'DMG verification failed'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "refusing to overwrite existing output: $OUT"
mv -n -- "$TMP_DMG" "$OUT"
[ -f "$OUT" ] && [ ! -e "$TMP_DMG" ] || fail 'could not place DMG at output path'

echo "Created: $OUT"
