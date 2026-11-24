#!/usr/bin/env bash
# Builds a release FileOSApp and wraps it in FileOS.app (macOS only).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product FileOSApp
bin="$(swift build -c release --show-bin-path)/FileOSApp"

app="FileOS.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/FileOS"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.betterfiles.FileOS</string>
    <key>CFBundleName</key><string>FileOS</string>
    <key>CFBundleDisplayName</key><string>FileOS</string>
    <key>CFBundleExecutable</key><string>FileOS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Save Link to FileOS</string></dict>
            <key>NSMessage</key><string>saveLink</string>
            <key>NSPortName</key><string>FileOS</string>
            <key>NSSendTypes</key><array><string>public.url</string><string>public.utf8-plain-text</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Built $app"
