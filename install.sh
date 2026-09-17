#!/bin/bash
# FinderTools 一键安装脚本
# 用法:复制下面这行到「终端」回车即可:
#   curl -fsSL https://raw.githubusercontent.com/lloongwa/FinderTools/main/install.sh | bash
set -e

APP="FinderTools.app"
VER="2.1.0"
BASE="https://github.com/lloongwa/FinderTools/releases/download/v$VER"

say() { printf '%s\n' "$*"; }

TMP="$(mktemp -d)"
DMG="$TMP/FinderTools.dmg"
MP="$TMP/volume"
cleanup() { hdiutil detach "$MP" -quiet >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

say "==> 下载 FinderTools v$VER"
curl -fSL --progress-bar -o "$DMG" "$BASE/FinderTools-$VER.dmg"

say "==> 挂载安装镜像"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MP" -quiet

say "==> 安装到 Applications(自动清理旧版本,避免右键菜单重复)"
TARGET="/Applications/$APP"
rm -rf "$TARGET" "$HOME/Applications/$APP"
if ! cp -R "$MP/$APP" /Applications/ 2>/dev/null; then
    TARGET="$HOME/Applications/$APP"
    mkdir -p "$HOME/Applications"
    cp -R "$MP/$APP" "$HOME/Applications/"
fi

say "==> 解除 macOS 下载隔离(一次性)"
xattr -dr com.apple.quarantine "$TARGET"

say "==> 刷新右键菜单"
hdiutil detach "$MP" -quiet >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
killall Finder >/dev/null 2>&1 || true

say ""
say "✅ 安装完成:$TARGET"
say "   右键任意文件/文件夹 → 服务,即可看到 13 个操作"
say "   (如果菜单没出现,等几秒或执行一次:killall Finder)"
