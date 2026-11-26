#!/bin/sh
# 編譯並打包成 build/現場擴音.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/現場擴音.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DJIPA" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 設定 SIGN_IDENTITY 可用憑證簽名；未設定則使用臨時簽名
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Resources/DJIPA.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "完成：$APP"
