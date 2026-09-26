#!/usr/bin/env bash
# Build PhoneBattery.app:
#   Contents/MacOS/PhoneBattery                 the menu bar app + desktop card
#   Contents/PlugIns/PhoneBatteryWidget.appex   the WidgetKit extension
#
# No adb, no network, no third-party binaries, no Xcode project.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/PhoneBattery.app"
CACHE="$HERE/.cache"
SRC="$HERE/PhoneBatteryBLEApp.swift"
WIDGET_SRC="$HERE/Widget/PhoneBatteryWidget.swift"
WIDGET_VIEW_SRC="$HERE/Widget/WidgetView.swift"
APPEX="$APP/Contents/PlugIns/PhoneBatteryWidget.appex"

ARCH="$(uname -m)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx)"
SDK_BUILD="$(xcrun --show-sdk-build-version --sdk macosx 2>/dev/null || echo "$SDK_VERSION")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE"

echo "==> swiftc: menu bar app"
TMPDIR="$CACHE" swiftc -O \
  -module-cache-path "$CACHE/modules" \
  -Xcc -fmodules-cache-path="$CACHE/clang" \
  "$SRC" -o "$APP/Contents/MacOS/PhoneBattery"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PhoneBattery</string>
    <key>CFBundleDisplayName</key><string>PhoneBattery</string>
    <key>CFBundleIdentifier</key><string>com.dsh.phonebattery.menubar</string>
    <key>CFBundleExecutable</key><string>PhoneBattery</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>读取手机的蓝牙电池服务，用来在菜单栏和桌面小窗显示手机电量。</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>读取手机的蓝牙电池服务，用来在菜单栏和桌面小窗显示手机电量。</string>
</dict>
</plist>
PLIST

echo "==> swiftc: widget extension"
mkdir -p "$APPEX/Contents/MacOS"
# -e _NSExtensionMain is essential: app extensions are launched as XPC services
# and entered through NSExtensionMain, which bootstraps the extension point's
# principal class. Without it the binary has a plain Swift `main`, chronod's
# descriptor query fails with "connection to service ... was invalidated"
# (pid -1), and the widget never appears in the gallery even though everything
# else — registration, platform keys, sandbox, Team ID — is correct.
if TMPDIR="$CACHE" swiftc -O -parse-as-library \
      -target "$ARCH-apple-macosx14.0" \
      -sdk "$SDK" \
      -module-cache-path "$CACHE/modules" \
      -Xcc -fmodules-cache-path="$CACHE/clang" \
      -framework WidgetKit -framework SwiftUI \
      -Xlinker -e -Xlinker _NSExtensionMain \
      "$WIDGET_SRC" "$WIDGET_VIEW_SRC" -o "$APPEX/Contents/MacOS/PhoneBatteryWidget" 2>"$CACHE/widget.log"; then
  cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PhoneBatteryWidget</string>
    <key>CFBundleDisplayName</key><string>手机电量</string>
    <key>CFBundleIdentifier</key><string>com.dsh.phonebattery.menubar.widget</string>
    <key>CFBundleExecutable</key><string>PhoneBatteryWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Without these platform keys macOS does not treat the bundle as a
         macOS app extension at all: pluginkit registers it, but the widget
         never appears in the gallery. Xcode normally injects them. -->
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTPlatformVersion</key><string>${SDK_VERSION}</string>
    <key>DTSDKName</key><string>macosx${SDK_VERSION}</string>
    <key>DTSDKBuild</key><string>${SDK_BUILD}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
  echo "    widget extension built"
else
  echo "    WIDGET BUILD FAILED — app still usable, no widget:"
  sed 's/^/      /' "$CACHE/widget.log" | head -20
  rm -rf "$APPEX"
fi

echo "==> sign"
# macOS will not list a widget whose extension has no Team ID, so prefer a real
# signing identity and fall back to ad-hoc only when none exists.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
SIGN_ID="${IDENTITY:--}"
echo "    identity: ${IDENTITY:-ad-hoc (no Team ID — the widget will NOT appear)}"
# The widget extension MUST carry the app-sandbox entitlement: macOS silently
# refuses to register an unsandboxed widget extension (pluginkit -a still
# returns 0, but the extension never appears in the widget gallery).
if [ -d "$APPEX" ]; then
  cat > "$CACHE/appex.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign "$SIGN_ID" --entitlements "$CACHE/appex.entitlements" "$APPEX" \
    || echo "    (appex codesign failed)"
fi
codesign --force --sign "$SIGN_ID" "$APP" || echo "    (app codesign skipped)"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Signature" | sed 's/^/    app: /'
[ -d "$APPEX" ] && codesign -dv "$APPEX" 2>&1 | grep -E "TeamIdentifier|Signature" | sed 's/^/    appex: /'

echo
echo "built: $APP  ($(du -sh "$APP" | cut -f1))"
ls -1 "$APP/Contents/PlugIns" 2>/dev/null | sed 's/^/  plugin: /' || true
