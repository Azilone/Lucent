#!/bin/zsh
# Builds a universal Lucent.app into build/.
#   --install  copy it to /Applications
#   --zip      also create build/Lucent-<version>.zip for a GitHub release
set -e
cd "$(dirname "$0")"
VERSION=1.1
BUILD=2
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS 2>&1 | grep -v "x86_64 architecture is deprecated" || true
BIN=$(swift build -c release $ARCHS --show-bin-path)
APP=build/Lucent.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Lucent" "$APP/Contents/MacOS/Lucent"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Lucent" 2>/dev/null
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
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/Azilone/Lucent/main/appcast.xml</string>
<key>SUPublicEDKey</key><string>lAHQmRGxkZTj7nSYMESEzsRtqHuL97wsBLM8rpNb5LA=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PL
# Sign with an Apple Development identity if there is one (keeps Accessibility
# permission across rebuilds), ad-hoc otherwise.
if security find-identity -v -p codesigning | grep -q "Apple Development"; then ID="Apple Development"; else ID=-; fi
codesign --force --deep --sign "$ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$ID" "$APP"
echo "Built $APP"
if [[ " $* " == *" --zip "* ]]; then
  ditto -c -k --keepParent "$APP" "build/Lucent-$VERSION.zip"
  echo "Zipped build/Lucent-$VERSION.zip"
fi
if [[ " $* " == *" --install "* ]]; then
  pkill -x Lucent 2>/dev/null || true
  rm -rf /Applications/Lucent.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Lucent.app"
fi
