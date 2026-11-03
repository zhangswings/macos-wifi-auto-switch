#!/bin/bash
#
# 一键编译打包 macOS WiFi 自动切换为 .app
# 用法：
#   ./build.sh            # 仅生成到 ./build/WiFi 自动切换.app
#   ./build.sh --install  # 额外安装到 ~/Applications
#
set -e

APP_NAME="WiFi 自动切换"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

command -v xcrun >/dev/null 2>&1 || { echo "需要先安装 Xcode Command Line Tools：xcode-select --install"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译 SwiftUI 应用…"
xcrun swiftc -O -parse-as-library -framework SwiftUI -framework AppKit \
    -o "$APP/Contents/MacOS/WiFiAutoSwitch" "$ROOT/WiFiAutoSwitch.swift"

cp "$ROOT/wifi-auto-switch.sh" "$APP/Contents/Resources/wifi-auto-switch.sh"
cp "$ROOT/com.user.wifiautoswitch.plist" "$APP/Contents/Resources/com.user.wifiautoswitch.plist"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WiFi 自动切换</string>
    <key>CFBundleDisplayName</key>
    <string>WiFi 自动切换</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.wifiautoswitch.app</string>
    <key>CFBundleExecutable</key>
    <string>WiFiAutoSwitch</string>
    <key>CFBundleVersion</key>
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/WiFiAutoSwitch"
echo "已生成：$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "已安装到 ~/Applications/$APP_NAME.app"
fi
