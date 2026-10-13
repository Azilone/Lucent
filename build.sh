#!/bin/zsh
# Builds Lucent.app into build/. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Lucent.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Lucent "$APP/Contents/MacOS/Lucent"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Lucent</string>
<key>CFBundleIdentifier</key><string>design.personalize.lucent</string>
<key>CFBundleName</key><string>Lucent</string>
<key>CFBundleDisplayName</key><string>Lucent</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PL
# Sign with an Apple Development identity if there is one (keeps Accessibility
# permission across rebuilds), ad-hoc otherwise.
if security find-identity -v -p codesigning | grep -q "Apple Development"; then
  codesign --force --sign "Apple Development" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  pkill -x Lucent 2>/dev/null || true
  rm -rf /Applications/Lucent.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Lucent.app"
fi
