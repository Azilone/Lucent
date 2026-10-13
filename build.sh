#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Vivid.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Vivid "$APP/Contents/MacOS/Vivid"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Vivid</string>
<key>CFBundleIdentifier</key><string>design.personalize.vivid</string>
<key>CFBundleName</key><string>Vivid</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "OK: $APP"
