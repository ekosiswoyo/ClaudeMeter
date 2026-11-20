#!/bin/sh
# Builds ClaudeMeter.app (optimized, size-stripped) next to this script.
set -e; cd "$(dirname "$0")"
APP=ClaudeMeter.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -Osize -whole-module-optimization main.swift -o "$APP/Contents/MacOS/ClaudeMeter"
strip -x "$APP/Contents/MacOS/ClaudeMeter"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ClaudeMeter</string>
<key>CFBundleIdentifier</key><string>local.claudemeter</string>
<key>CFBundleExecutable</key><string>ClaudeMeter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PL
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP ($(du -sh "$APP" | cut -f1))"
