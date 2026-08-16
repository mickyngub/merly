#!/bin/bash
# bundle.sh — build a release binary and assemble "Merlyn.app".
#
# Signing is automatic. In preference order:
#   • A "Developer ID Application" certificate, + Hardened Runtime (--options
#     runtime) — what notarization would need, if this project ever shipped
#     binaries.
#   • The local self-signed identity from scripts/make-signing-cert.sh. Merlyn
#     ships as source and a locally built app is never quarantined, so this is
#     not about Gatekeeper — it is about having a code identity that survives a
#     rebuild, which is what macOS hangs the notification permission and the
#     Keychain "Always Allow" grants on.
#   • Ad-hoc, as a last resort. It runs, but both of those break every build.
#
# Overrides (env):
#   MERLYN_VERSION=1.2         marketing version (CFBundleShortVersionString)
#   MERLYN_BUILD=7             build number      (CFBundleVersion)
#   SIGN_IDENTITY="..."        force a specific codesign identity
#   MERLYN_SIGN_IDENTITY="..." rename the local self-signed identity to look for
#   MERLYN_ADHOC=1             force ad-hoc signing
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
    <key>CFBundleIdentifier</key><string>com.mickyngub.merlyn.resources</string>
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
    <string>com.mickyngub.merlyn</string>
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
# Identity preference: Developer ID → the local self-signed identity → ad-hoc.
#
# The middle rung matters more than it looks. Ad-hoc signing gives a designated
# requirement of `cdhash H"<this build>"`, so every rebuild is a *different app* to
# macOS and Keychain "Always Allow" is re-prompted forever.
# scripts/make-signing-cert.sh creates an identity that survives rebuilds.
#
# It has no bearing on notifications, despite looking like it should — that was
# measured. See docs/specs/distribution.md § Notifications.
#
# scripts/Merlyn.entitlements is an EMPTY dict, and has to stay literally empty —
# no XML comments. AMFI's parser rejects them outright ("Failed to parse
# entitlements: AMFIUnserializeXML: syntax error"), which is why the rationale
# lives here instead of in the file:
#
#   Merlyn runs OUTSIDE the App Sandbox by design — its whole job is reading other
#   tools' credentials from the login Keychain and their config files under $HOME
#   (~/.codex, ~/.claude*, ~/.kimi-code), which the sandbox forbids. That is also
#   why it cannot ship on the Mac App Store as-is. Hardened Runtime IS enabled
#   (--options runtime) so the app could be notarized, and it needs no exceptions:
#   Keychain items are read by shelling out to /usr/bin/security rather than the
#   in-process APIs, file reads are ordinary user-owned dotfiles, and network
#   access is the default outbound-client behaviour.
ENTITLEMENTS="scripts/Merlyn.entitlements"
LOCAL_IDENTITY="${MERLYN_SIGN_IDENTITY:-Merlyn Local Signing}"
IDENTITY="${SIGN_IDENTITY:-}"
ADHOC_REASON="forced by MERLYN_ADHOC=1"
if [ -z "$IDENTITY" ] && [ "${MERLYN_ADHOC:-0}" != "1" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1 || true)"
  if [ -z "$IDENTITY" ]; then
    if security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
      IDENTITY="$LOCAL_IDENTITY"
    else
      ADHOC_REASON="no signing identity found"
    fi
  fi
fi

if [ -n "$IDENTITY" ]; then
  # A timestamp is only meaningful for a signature someone else will verify after
  # the certificate expires — that is notarisation's concern, not a local build's,
  # and the timestamp authority is a network round trip on every build.
  TS="--timestamp"
  if [ "$IDENTITY" = "$LOCAL_IDENTITY" ]; then
    TS="--timestamp=none"
    echo "▶ Signing with the local identity + Hardened Runtime:"
  else
    echo "▶ Signing with Developer ID + Hardened Runtime:"
  fi
  echo "    $IDENTITY"
  echo "  (First build with a new identity: macOS asks once for Keychain access to"
  echo "   the signing key — choose Always Allow.)"
  # Sign the nested bundle inside-out first, then the app itself.
  if [ -e "$NESTED" ]; then
    codesign --force --options runtime $TS --sign "$IDENTITY" "$NESTED"
  fi
  codesign --force --options runtime $TS \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "✔ Signed with a stable identity, so Keychain grants survive rebuilds."
else
  echo "▶ Ad-hoc signing ($ADHOC_REASON)."
  echo "  Gatekeeper is not the problem — an app you built locally is never"
  echo "  quarantined. The cost is that every rebuild is a NEW code identity, so"
  echo "  macOS re-asks for Keychain access after each build."
  echo "  Fix it once with:  scripts/make-signing-cert.sh"
  echo "  Background: docs/specs/distribution.md."
  if [ -e "$NESTED" ]; then
    codesign --force --sign - "$NESTED"
  fi
  codesign --force --sign - "$APP"
fi

codesign --verify --strict "$APP"

echo "Built:   $APP  (v${VERSION} build ${BUILD})"
echo "Try it:  open \"$APP\"           (runs it from here, leaves /Applications alone)"
echo "Install: scripts/install.sh    (quits any running copy, then installs it)"
