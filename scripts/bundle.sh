#!/bin/bash
# bundle.sh — build a release binary and assemble "Lens.app".
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Lens.app"
BIN=".build/release/Lens"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lens"

# App icon (Clawd mascot). Regenerate from the sprite sheet if it's missing.
[ -f "scripts/Lens.icns" ] || uv run scripts/make-icon.py
cp "scripts/Lens.icns" "$APP/Contents/Resources/Lens.icns"

# Bundled resources (sprite sheets). Bundle.module resolves this next to the binary.
cp -R ".build/release/Lens_Lens.bundle" "$APP/Contents/MacOS/" 2>/dev/null \
  || echo "warning: Lens_Lens.bundle not found (no resources?)"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Lens</string>
    <key>CFBundleIdentifier</key>
    <string>sh.micky.lens</string>
    <key>CFBundleName</key>
    <string>Lens</string>
    <key>CFBundleIconFile</key>
    <string>Lens</string>
    <key>CFBundleDisplayName</key>
    <string>Lens</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $APP"
echo "Run:   open \"$APP\""
