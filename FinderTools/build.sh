#!/bin/bash
# FinderTools 构建与安装脚本(纯 bash,只需要 Xcode Command Line Tools,不需要 Python)
#
# 用法:
#   bash build.sh build      编译出 FinderTools.app(当前目录)
#   bash build.sh install    编译 + 装入 ~/Applications + 移除旧版 workflow + 刷新服务注册
#   bash build.sh uninstall  从 ~/Applications 移除并刷新服务注册
#   bash build.sh selftest   编译后跑冒烟测试(拷贝/剪切粘贴/压缩/git 状态)
set -euo pipefail
cd "$(dirname "$0")"

NAME="FinderTools"
APP="$NAME.app"
BIN="$APP/Contents/MacOS/$NAME"
DEST="$HOME/Applications/$APP"
PBS="/System/Library/CoreServices/pbs"

# 旧版 workflow 方案生成的 13 个操作,装 App 版时必须移除,否则右键菜单重复
LEGACY_WORKFLOWS=(copy_path copy_name new_file compress_zip compress_targz
                  copy_to move_to cut paste_cut git_status open_terminal
                  open_vscode toggle_hidden)

build() {
    echo "==> 编译 main.swift (universal2)"
    mkdir -p "$APP/Contents/MacOS"
    local tmpout
    tmpout="$(mktemp -d)"
    # Swift 6.4 驱动已移除 -arch,分别按 target 编译再 lipo 合并
    MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -O -swift-version 5 \
        -target arm64-apple-macosx13.0 -o "$tmpout/arm" main.swift
    MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -O -swift-version 5 \
        -target x86_64-apple-macosx13.0 -o "$tmpout/x86" main.swift
    lipo -create -output "$BIN" "$tmpout/arm" "$tmpout/x86"
    rm -rf "$tmpout"

    echo "==> 组装 $APP"
    cp Info.plist "$APP/Contents/Info.plist"

    echo "==> ad-hoc 签名"
    codesign --force --sign - "$APP"
    plutil -lint "$APP/Contents/Info.plist"
    echo "==> 编译完成: $PWD/$APP"
}

install_app() {
    build
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"

    echo "==> 移除旧版 13 个 .workflow(避免右键菜单重复)"
    for k in "${LEGACY_WORKFLOWS[@]}"; do
        rm -rf "$HOME/Library/Services/$k.workflow"
    done

    echo "==> 刷新服务注册"
    "$PBS" -flush >/dev/null 2>&1 || true
    "$PBS" -update >/dev/null 2>&1 || true   # 触发重扫;仅 -flush 时新 App 服务经常迟迟不注册
    killall -HUP pbs >/dev/null 2>&1 || true
    echo "==> 已安装: $DEST"
    echo "    如果右键菜单里没立刻出现,先 killall Finder,再不行就注销重登录。"
}

uninstall_app() {
    rm -rf "$DEST"
    "$PBS" -flush >/dev/null 2>&1 || true
    killall -HUP pbs >/dev/null 2>&1 || true
    echo "已卸载 $DEST"
}

selftest() {
    [ -x "$BIN" ] || build
    local pass=0 fail=0
    local tmp
    tmp="$(mktemp -d /tmp/finder-tools-selftest.XXXXXX)"
    local old_clip
    old_clip="$(pbpaste)"    # 测试会占用剪贴板,结束时恢复(仅纯文本)

    ok()   { pass=$((pass + 1)); echo "  [ok]   $1"; }
    bad()  { fail=$((fail + 1)); echo "  [FAIL] $1"; }
    check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi }

    echo "hello" > "$tmp/a.txt"
    mkdir -p "$tmp/dir"
    echo "# inner" > "$tmp/dir/inner.md"

    echo "==> 拷贝路径"
    "$BIN" --run "拷贝路径" "$tmp/a.txt"
    check "写入正确"   "[ \"\$(pbpaste)\" = \"$tmp/a.txt\" ]"
    sleep 3
    check "3 秒后仍在" "[ \"\$(pbpaste)\" = \"$tmp/a.txt\" ]"

    echo "==> 拷贝名称"
    "$BIN" --run "拷贝名称" "$tmp/a.txt" "$tmp/dir"
    check "多个名称换行分隔" "[ \"\$(pbpaste)\" = \"a.txt
dir\" ]"

    echo "==> 压缩"
    "$BIN" --run "压缩为 ZIP" "$tmp/dir"
    check "zip 生成"   "[ -f \"$tmp/dir.zip\" ]"
    "$BIN" --run "压缩为 TAR.GZ" "$tmp/dir"
    check "tar.gz 生成" "[ -f \"$tmp/dir.tar.gz\" ]"
    # 注意:管道里不要用 grep -q。pipefail 下 grep -q 提前退出会让上游收 SIGPIPE
    # (退出码 141),整条管道被误判失败,且是随机的。>/dev/null 让 grep 吃完输入。
    check "zip 内容"   "unzip -l \"$tmp/dir.zip\" 2>/dev/null | grep inner.md >/dev/null"

    echo "==> 剪切 + 粘贴到此处"
    echo "move" > "$tmp/movable.txt"
    mkdir -p "$tmp/dest"
    "$BIN" --run "剪切" "$tmp/movable.txt"
    check "cut-list 已写" "grep -q \"$tmp/movable.txt\" \"$HOME/.local/state/finder-tools/cut-list\""
    "$BIN" --run "粘贴到此处" "$tmp/dest"
    check "已移动"     "[ -f \"$tmp/dest/movable.txt\" ] && [ ! -e \"$tmp/movable.txt\" ]"

    echo "==> Git 状态"
    git init -q -b main "$tmp/repo"
    git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    "$BIN" --run "Git 状态" "$tmp/repo"
    check "包含分支名" "pbpaste | grep 'branch:  main' >/dev/null"

    echo "==> 空参数防御(不应改写剪贴板)"
    "$BIN" --run "拷贝路径"
    check "剪贴板未被清空" "pbpaste | grep 'branch:  main' >/dev/null"

    printf '%s' "$old_clip" | pbcopy
    rm -rf "$tmp"
    echo "==> 通过 $pass 项,失败 $fail 项"
    [ "$fail" -eq 0 ]
}

case "${1:-build}" in
    build)     build ;;
    install)   install_app ;;
    uninstall) uninstall_app ;;
    selftest)  selftest ;;
    *) echo "用法: bash build.sh [build|install|uninstall|selftest]"; exit 1 ;;
esac
