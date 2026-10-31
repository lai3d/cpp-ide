#!/usr/bin/env bash
# Builds a release CppIDE.app (and CppIDE.zip) into ./build. Ad-hoc signed: fine for local
# use; distributing to others needs a Developer ID signature + notarization (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed "s/^v//" || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CppIDE"
APP=build/CppIDE.app

rm -rf "$APP" build/CppIDE.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CppIDE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CppIDE</string>
    <key>CFBundleDisplayName</key><string>CppIDE</string>
    <key>CFBundleIdentifier</key><string>io.github.lai3d.cppide</string>
    <key>CFBundleExecutable</key><string>CppIDE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
ditto -c -k --keepParent "$APP" build/CppIDE.zip
echo "Built $APP ($VERSION, build $BUILD_NUMBER) and build/CppIDE.zip"
