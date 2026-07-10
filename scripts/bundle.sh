#!/bin/bash
# bundle.sh — build a release binary and assemble "Merlyn.app".
set -euo pipefail

cd "$(dirname "$0")/.."

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
cp -R ".build/release/Merlyn_Merlyn.bundle" "$APP/Contents/MacOS/" 2>/dev/null \
  || echo "warning: Merlyn_Merlyn.bundle not found (no resources?)"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
