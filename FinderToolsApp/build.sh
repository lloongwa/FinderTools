#!/bin/bash
# 编译 FinderTools 菜单栏 App 并打包成 .app
#
# 只需要 Xcode Command Line Tools(不需要完整 Xcode.app)。
# 使用 ad-hoc 签名(--sign -),本机自用足够;首次启动若被 Gatekeeper 拦下,
# 到「系统设置 → 隐私与安全性」点「仍要打开」即可,之后不再提示。
set -euo pipefail
cd "$(dirname "$0")"

NAME="FinderTools"
APP="$NAME.app"
SRC="main.swift"
BIN="$NAME"

echo "==> 编译 $SRC"
swiftc -O -swift-version 5 \
    -target arm64-apple-macosx13.0 \
    -o "$BIN" "$SRC"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$BIN"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

# 本地生成的 app 本不该带隔离属性,清一下更保险
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> 完成: $(pwd)/$APP"
echo "    双击即可运行(菜单栏出现图标,不占 Dock)"

if [[ "${1:-}" == "--run" ]]; then
    echo "==> 启动"
    open "$APP"
fi
