#!/bin/zsh
# 构建并组装 ScreenMaintainer.app（无需 Xcode，仅需 Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="ScreenMaintainer"
APP="build/$APP_NAME.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ ad-hoc 签名"
codesign --force --sign - "$APP"

echo "✓ 完成：$APP"
echo "  试运行:  open $APP"
echo "  安装:    cp -R $APP /Applications/ && open /Applications/$APP_NAME.app"
