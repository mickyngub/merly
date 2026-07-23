#!/bin/bash
# dmg.sh — build Merlyn.app and package it as a distributable .dmg.
#
# Works with no Apple Developer account: produces an unsigned/ad-hoc DMG that
# recipients open once past Gatekeeper (instructions printed at the end).
#
# Once you have a Developer ID certificate + stored notary credentials, run:
#     NOTARIZE=1 scripts/dmg.sh
# to sign, notarize, and staple a zero-warning DMG. See docs/specs/distribution.md.
#
# Overrides (env):
#   MERLYN_VERSION=1.2      version baked into the app + DMG name (default 1.0)
#   MERLYN_BUILD=7          build number (default 1)
#   NOTARIZE=1              notarize + staple (requires a Developer ID + creds)
#   NOTARY_PROFILE=name     notarytool keychain profile (default "merlyn-notary")
#   SIGN_IDENTITY="..."     force a specific codesign identity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

VERSION="${MERLYN_VERSION:-1.0}"
export MERLYN_VERSION="$VERSION"          # keep bundle.sh in lockstep
NOTARY_PROFILE="${NOTARY_PROFILE:-merlyn-notary}"

# Build + sign the .app (bundle.sh signs with Developer ID if one exists).
"$SCRIPT_DIR/bundle.sh"

APP="build/Merlyn.app"
DMG="dist/Merlyn-${VERSION}.dmg"
mkdir -p dist
rm -f "$DMG"

# Detect the same signing identity bundle.sh used (for signing the DMG itself).
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ "${MERLYN_ADHOC:-0}" != "1" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1 || true)"
fi

# Stage the .app + an /Applications drop target, then make a compressed DMG.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Merlyn.app"        # ditto preserves the code signature
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Merlyn ${VERSION}" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null
echo "Packaged: $DMG"

# Sign the DMG if we have a real identity.
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$DMG"
  echo "✔ DMG signed."
fi

# Notarize + staple only when explicitly requested and a real identity exists.
if [ "${NOTARIZE:-0}" = "1" ] && [ -n "$IDENTITY" ]; then
  echo "▶ Notarizing with profile '$NOTARY_PROFILE' (this can take a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "✔ Notarized + stapled. This DMG opens with no Gatekeeper warning."
  exit 0
fi

if [ "${NOTARIZE:-0}" = "1" ] && [ -z "$IDENTITY" ]; then
  echo "⚠ NOTARIZE=1 but no Developer ID certificate was found — produced an unsigned DMG."
fi

STATE="unsigned (ad-hoc)"
[ -n "$IDENTITY" ] && STATE="signed but NOT notarized"
cat <<EOF

This DMG is $STATE. Recipients open it once via either:
  • System Settings → Privacy & Security → "Open Anyway", then confirm; or
  • xattr -dr com.apple.quarantine /Applications/Merlyn.app  (then open normally)

For a zero-warning DMG: enroll in Apple Developer, set up notarization, then run
  NOTARIZE=1 scripts/dmg.sh
See docs/specs/distribution.md for the full one-time setup.
EOF
