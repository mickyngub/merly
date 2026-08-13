#!/bin/bash
# bundle.sh — build a release binary and assemble "Merlyn.app".
#
# Signing is automatic and optional:
#   • If a "Developer ID Application" certificate is in your keychain, the app
#     is signed with it + Hardened Runtime (--options runtime) — what
#     notarization would need, if this project ever shipped binaries.
#   • Otherwise it is ad-hoc signed, which is the normal path: Merlyn ships as
#     source, and an app built locally is never quarantined. Only a copy you
#     *download* hits Gatekeeper, and we publish none.
#
# Overrides (env):
#   MERLYN_VERSION=1.2   marketing version (CFBundleShortVersionString)
#   MERLYN_BUILD=7       build number      (CFBundleVersion)
#   SIGN_IDENTITY="..."  force a specific codesign identity
#   MERLYN_ADHOC=1       force ad-hoc signing even if a Developer ID exists
set -euo pipefail

cd "$(dirname "$0")/.."

# Merlyn is source-distributed (see SECURITY.md), but version tags exist so a
# build can say which numbered version it came from: the marketing version is
# the nearest `v*` tag, and the build number is the commit count — monotonic,
# numeric (CFBundleVersion must be), and mappable back to the exact commit a
# bug report came from via `git log`.
VERSION="${MERLYN_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0}"
BUILD="${MERLYN_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT="© 2026 Pichaya Puttekulangkura. MIT Licensed."

swift build -c release

APP="build/Merlyn.app"
BIN=".build/release/Merlyn"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Merlyn"

# App icon (Clawd mascot). Regenerate from the sprite sheet if it's missing.
[ -f "scripts/Merlyn.icns" ] || uv run scripts/make-icon.py
cp "scripts/Merlyn.icns" "$APP/Contents/Resources/Merlyn.icns"

# Bundled resources (sprite sheets). Bundle.module resolves this next to the binary.
NESTED="$APP/Contents/MacOS/Merlyn_Merlyn.bundle"
cp -R ".build/release/Merlyn_Merlyn.bundle" "$APP/Contents/MacOS/" 2>/dev/null \
  || echo "warning: Merlyn_Merlyn.bundle not found (no resources?)"

# SwiftPM emits a FLAT resource bundle (Resources/ + no Info.plist), which
# codesign refuses to seal ("bundle format unrecognized"). Repack it into a
# standard Contents/ bundle layout so it can be signed and notarized. Bundle.module
# still resolves resources from Contents/Resources at runtime.
if [ -d "$NESTED" ] && [ ! -f "$NESTED/Contents/Info.plist" ]; then
  mkdir -p "$NESTED/Contents/Resources"
  [ -d "$NESTED/Resources" ] && mv "$NESTED"/Resources/* "$NESTED/Contents/Resources/" 2>/dev/null || true
  rmdir "$NESTED/Resources" 2>/dev/null || true
  cat > "$NESTED/Contents/Info.plist" <<'BPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>sh.micky.merlyn.resources</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Merlyn_Merlyn</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
BPLIST
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Merlyn</string>
    <key>CFBundleIdentifier</key>
    <string>sh.micky.merlyn</string>
    <key>CFBundleName</key>
    <string>Merlyn</string>
    <key>CFBundleIconFile</key>
    <string>Merlyn</string>
    <key>CFBundleDisplayName</key>
    <string>Merlyn</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
</dict>
</plist>
PLIST

# ── Signing ────────────────────────────────────────────────────────────────
ENTITLEMENTS="scripts/Merlyn.entitlements"
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ "${MERLYN_ADHOC:-0}" != "1" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1 || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "▶ Signing with Developer ID + Hardened Runtime:"
  echo "    $IDENTITY"
  # Sign the nested bundle inside-out first, then the app itself.
  if [ -e "$NESTED" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$NESTED"
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "✔ Signed with a real identity. Merlyn ships as source, so there is nothing"
  echo "  further to package — see docs/specs/distribution.md."
else
  echo "▶ No Developer ID identity found — ad-hoc signing. This is the normal path:"
  echo "  Merlyn ships as source, and an app you built locally is never quarantined,"
  echo "  so Gatekeeper won't gate it. macOS will re-ask for Keychain access after"
  echo "  each rebuild (every build is a new ad-hoc identity). See"
  echo "  docs/specs/distribution.md for why, and for the self-signed-cert fix."
  if [ -e "$NESTED" ]; then
    codesign --force --sign - "$NESTED"
  fi
  codesign --force --sign - "$APP"
fi

codesign --verify --strict "$APP"

echo "Built:   $APP  (v${VERSION} build ${BUILD})"
echo "Try it:  open \"$APP\"           (runs it from here, leaves /Applications alone)"
echo "Install: scripts/install.sh    (quits any running copy, then installs it)"
