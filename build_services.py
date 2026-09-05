#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mac-finder-tools: 生成 macOS Finder 右键「快速操作」(Quick Actions)

原理:每个快速操作就是一个 Automator .workflow bundle,丢进 ~/Library/Services/ 后
由系统 LaunchServices 扫描注册,出现在 Finder 右键菜单里。无需签名、无需付费账号。

用法:
    python3 build_services.py              # 生成全部并刷新服务注册
    python3 build_services.py --list       # 列出所有可用操作
    python3 build_services.py copy_path    # 只生成指定的操作
    python3 build_services.py --clean      # 删除已生成的全部操作
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import uuid

SERVICES_DIR = os.path.expanduser("~/Library/Services")
ACTION_BUNDLE = "/System/Library/Automator/Run Shell Script.action"
NIB_PATH = ACTION_BUNDLE + "/Contents/Resources/Base.lproj/main.nib"
PBS = "/System/Library/CoreServices/pbs"

# Automator 执行脚本时 PATH 很干净(不含 homebrew),这里统一补上
SCRIPT_HEADER = r'''export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}
target_dir() {
  if [ -d "$1" ]; then printf '%s' "$1"; else printf '%s' "$(dirname "$1")"; fi
}
uniq_path() {
  local p="$1"
  if [ ! -e "$p" ]; then printf '%s' "$p"; return; fi
  local d n ext base
  d="$(dirname "$p")"; n="$(basename "$p")"
  ext=""; base="$n"
  case "$n" in
    *.*) ext=".${n##*.}"; base="${n%.*}" ;;
  esac
  local i=1
  while [ -e "$d/${base}-${i}${ext}" ]; do i=$((i + 1)); done
  printf '%s' "$d/${base}-${i}${ext}"
}
'''

ACTIONS = [
    # ---------------------------------------------------------------
    {
        "key": "copy_path",
        "menu": "拷贝路径",
        "script": r'''out=""
n=0
for f in "$@"; do
  n=$((n + 1))
  if [ -z "$out" ]; then out="$f"; else out="$out
$f"; fi
done
printf '%s' "$out" | pbcopy
notify "拷贝路径" "已复制 ${n} 个路径到剪贴板"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "copy_name",
        "menu": "拷贝名称",
        "script": r'''out=""
n=0
for f in "$@"; do
  n=$((n + 1))
  b="$(basename "$f")"
  if [ -z "$out" ]; then out="$b"; else out="$out
$b"; fi
done
printf '%s' "$out" | pbcopy
notify "拷贝名称" "已复制 ${n} 个文件名"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "new_file",
        "menu": "新建文件…",
        "script": r'''d="$(target_dir "$1")"
name=$(osascript <<'AS' 2>/dev/null
try
  return text returned of (display dialog "文件名:" default answer "untitled.txt" with title "新建文件" with icon note)
on error
  return ""
end try
AS
)
if [ -z "$name" ]; then exit 0; fi
p="$(uniq_path "$d/$name")"
touch "$p"
notify "新建文件" "$(basename "$p")"
osascript -e "tell application \"Finder\" to reveal POSIX file \"$p\"" >/dev/null 2>&1
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1''',
    },
    # ---------------------------------------------------------------
    {
        "key": "compress_zip",
        "menu": "压缩为 ZIP",
        "script": r'''n=0
for f in "$@"; do
  d="$(dirname "$f")"; b="$(basename "$f")"
  out="$(uniq_path "$d/$b.zip")"
  ( cd "$d" && ditto -c -k --sequesterRsrc --keepParent "$b" "$(basename "$out")" )
  n=$((n + 1))
done
notify "压缩为 ZIP" "完成 ${n} 项"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "compress_targz",
        "menu": "压缩为 TAR.GZ",
        "script": r'''n=0
for f in "$@"; do
  d="$(dirname "$f")"; b="$(basename "$f")"
  out="$(uniq_path "$d/$b.tar.gz")"
  tar -czf "$out" -C "$d" "$b"
  n=$((n + 1))
done
notify "压缩为 TAR.GZ" "完成 ${n} 项"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "copy_to",
        "menu": "复制到…",
        "script": r'''target=$(osascript <<'AS' 2>/dev/null
try
  return POSIX path of (choose folder with prompt "选择目标文件夹")
on error
  return ""
end try
AS
)
if [ -z "$target" ]; then exit 0; fi
n=0
for f in "$@"; do
  cp -R "$f" "$target"
  n=$((n + 1))
done
notify "复制到" "${n} 项已复制到 $(basename "$target")"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "move_to",
        "menu": "移动到…",
        "script": r'''target=$(osascript <<'AS' 2>/dev/null
try
  return POSIX path of (choose folder with prompt "选择目标文件夹")
on error
  return ""
end try
AS
)
if [ -z "$target" ]; then exit 0; fi
n=0
for f in "$@"; do
  mv "$f" "$target"
  n=$((n + 1))
done
notify "移动到" "${n} 项已移动到 $(basename "$target")"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "cut",
        "menu": "剪切",
        "script": r'''state="$HOME/.local/state/finder-tools"
mkdir -p "$state"
cutfile="$state/cut-list"
: > "$cutfile"
n=0
for f in "$@"; do
  printf '%s\n' "$f" >> "$cutfile"
  n=$((n + 1))
done
notify "剪切" "已标记 ${n} 项,到目标文件夹右键选「粘贴到此处」"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "paste_cut",
        "menu": "粘贴到此处",
        "script": r'''state="$HOME/.local/state/finder-tools"
cutfile="$state/cut-list"
if [ ! -s "$cutfile" ]; then
  notify "粘贴到此处" "没有待剪切的项"
  exit 0
fi
target="$(target_dir "$1")"
n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ -e "$f" ]; then
    mv "$f" "$target" && n=$((n + 1))
  fi
done < "$cutfile"
: > "$cutfile"
notify "粘贴到此处" "已移动 ${n} 项到 $(basename "$target")"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "git_status",
        "menu": "Git 状态",
        "script": r'''out=""
summary=""
n=0
for f in "$@"; do
  d="$(target_dir "$f")"
  repo=$(cd "$d" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo" ]; then continue; fi
  br=$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
  st=$(cd "$repo" && git status --porcelain 2>/dev/null)
  cnt=$(printf '%s' "$st" | grep -c .)
  ahead=$(cd "$repo" && git rev-list --count @{upstream}..HEAD 2>/dev/null || echo "?")
  block="repo:   $repo
branch: $br
changed: $cnt files
ahead:  $ahead commit(s)"
  if [ -z "$out" ]; then out="$block"; else out="$out

$block"; fi
  summary="$summary$(basename "$repo")[$br:$cnt] "
  n=$((n + 1))
done
if [ -z "$out" ]; then
  notify "Git 状态" "选中的项不在 Git 仓库中"
  exit 0
fi
printf '%s\n' "$out" | pbcopy
notify "Git 状态" "${summary}(详情已复制到剪贴板)"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "open_terminal",
        "menu": "在此打开终端",
        "script": r'''for f in "$@"; do
  d="$(target_dir "$f")"
  open -a Terminal "$d"
done''',
    },
    # ---------------------------------------------------------------
    {
        "key": "open_vscode",
        "menu": "用 VS Code 打开",
        "script": r'''open -a "Visual Studio Code" "$@"
notify "VS Code" "已打开 $# 项"''',
    },
    # ---------------------------------------------------------------
    {
        "key": "toggle_hidden",
        "menu": "显示/隐藏 隐藏文件",
        "script": r'''cur=$(defaults read com.apple.finder AppleShowAllFiles 2>/dev/null)
if [ "$cur" = "1" ] || [ "$cur" = "true" ]; then
  defaults write com.apple.finder AppleShowAllFiles -bool false
  msg="已隐藏"
else
  defaults write com.apple.finder AppleShowAllFiles -bool true
  msg="已显示"
fi
killall Finder >/dev/null 2>&1
notify "隐藏文件" "${msg}(Finder 已重启)"''',
    },
]


def build_document_wflow(script: str) -> bytes:
    """构造 Automator Run Shell Script 工作流的 document.wflow"""
    action_uuid = str(uuid.uuid4()).upper()
    input_uuid = str(uuid.uuid4()).upper()
    output_uuid = str(uuid.uuid4()).upper()

    action = {
        "AMAccepts": {
            "Container": "List",
            "Optional": True,
            "Types": ["com.apple.cocoa.string"],
        },
        "AMActionVersion": "2.0.3",
        "AMApplication": ["Automator"],
        "AMParameterProperties": {
            "COMMAND_STRING": {},
            "CheckedForUserDefaultShell": {},
            "inputMethod": {},
            "shell": {},
            "source": {},
        },
        "AMProvides": {
            "Container": "List",
            "Types": ["com.apple.cocoa.string"],
        },
        "ActionBundlePath": ACTION_BUNDLE,
        "ActionName": "Run Shell Script",
        "ActionParameters": {
            "COMMAND_STRING": script,
            "CheckedForUserDefaultShell": True,
            "inputMethod": 1,      # 1 = 作为参数传入(而非 stdin)
            "shell": "/bin/bash",
            "source": "",
        },
        "BundleIdentifier": "com.apple.RunShellScript",
        "CFBundleVersion": "2.0.3",
        "CanShowSelectedItemsWhenRun": False,
        "CanShowWhenRun": True,
        "Category": ["AMCategoryUtilities"],
        "Class Name": "RunShellScriptAction",
        "InputUUID": input_uuid,
        "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
        "OutputUUID": output_uuid,
        "UUID": action_uuid,
        "UnlocalizedApplications": ["Automator"],
        "arguments": {
            "0": {
                "default value": "",
                "name": "input",
                "type": "actionInput",
                "uuid": input_uuid,
            },
            "1": {
                "default value": "",
                "name": "output",
                "type": "actionOutput",
                "uuid": output_uuid,
            },
        },
        "isViewVisible": True,
        "location": "383.000000:264.000000",
        "nibPath": NIB_PATH,
    }

    # 实证依据:本机可正常出现在 Finder 右键的第三方 workflow(Open in ZCode.workflow)
    # 用的就是 servicesMenu;而 quickAction 在本机没有任何已装 workflow 采用,
    # 实测也不会出现在右键菜单里。故固定使用 servicesMenu。
    meta = {
        "serviceApplicationBundleID": "com.apple.finder",
        "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
        "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
        "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
        "serviceProcessesInput": False,
        "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
    }

    doc = {
        "AMApplicationBuild": "5210.3",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [{"action": action, "isViewVisible": True}],
        "connectors": {},
        "workflowMetaData": meta,
    }
    return plistlib.dumps(doc)


def build_info_plist(key: str, menu_title: str) -> bytes:
    """构造 .workflow 的 Contents/Info.plist(NSServices 声明 + 标准 bundle 字段)"""
    info = {
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleIdentifier": "com.local.findertools.%s" % key,
        "CFBundleName": menu_title,
        "CFBundleShortVersionString": "1.0",
        "NSServices": [
            {
                "NSMenuItem": {"default": menu_title},
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": {
                    "NSApplicationIdentifier": "com.apple.finder"
                },
                # 必须用具体 UTI。曾经用 public.item,而它是抽象顶层类型
                # (conforms(to: .data) == false),系统不会拿它去匹配任何实际文件,
                # 结果服务永远不出现在右键菜单里。
                # 实测:系统自带 5 个 + 第三方 Open in ZCode 用的全是具体类型。
                #   public.data      -> 所有文件(README.md/build_services.py 等均继承自它)
                #   public.folder    -> 所有文件夹(ZCode 用的就是它)
                #   public.directory -> 目录别名
                "NSSendFileTypes": ["public.data", "public.folder",
                                    "public.directory"],
            }
        ],
    }
    return plistlib.dumps(info)


def write_workflow(action: dict, services_dir: str) -> str:
    key = action["key"]
    wf_dir = os.path.join(services_dir, "%s.workflow" % key)
    contents = os.path.join(wf_dir, "Contents")

    if os.path.exists(wf_dir):
        shutil.rmtree(wf_dir)
    os.makedirs(contents, exist_ok=True)

    script = SCRIPT_HEADER + "\n" + action["script"]
    wf_data = build_document_wflow(script)

    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        f.write(build_info_plist(key, action["menu"]))
    # 只写 Contents/document.wflow:
    #   现代 Automator 与本机第三方 workflow(如 Open in ZCode.workflow)都用这个位置。
    #   曾经同时写 Contents/Resources/document.wflow 做兼容,结果 codesign 因同名子资源
    #   冲突而失败,故只保留一处。
    with open(os.path.join(contents, "document.wflow"), "wb") as f:
        f.write(wf_data)

    # 不签名:本机第三方 workflow(Open in ZCode.workflow)同样是未签名的,
    # 且 codesign 对这些 bundle 会因子资源问题失败。签名并非必需。
    return wf_dir


def flush_services():
    """刷新系统服务注册缓存,让新生成的快速操作立刻出现"""
    try:
        subprocess.run([PBS, "-flush"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/killall", "-HUP", "pbs"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print("  ! 刷新服务注册失败: %s" % e)


def main():
    ap = argparse.ArgumentParser(description="生成 Finder 右键快速操作")
    ap.add_argument("keys", nargs="*", help="只生成指定的操作(默认全部)")
    ap.add_argument("--list", action="store_true", help="列出所有操作")
    ap.add_argument("--clean", action="store_true", help="删除已生成的操作")
    args = ap.parse_args()

    if args.list:
        for a in ACTIONS:
            print("  %-16s %s" % (a["key"], a["menu"]))
        return

    if args.clean:
        removed = 0
        for a in ACTIONS:
            d = os.path.join(SERVICES_DIR, "%s.workflow" % a["key"])
            if os.path.isdir(d):
                shutil.rmtree(d)
                removed += 1
        flush_services()
        print("已移除 %d 个操作。" % removed)
        return

    selected = ACTIONS
    if args.keys:
        wanted = set(args.keys)
        selected = [a for a in ACTIONS if a["key"] in wanted]
        unknown = wanted - {a["key"] for a in ACTIONS}
        if unknown:
            print("未知操作: %s" % ", ".join(sorted(unknown)))
            sys.exit(1)

    os.makedirs(SERVICES_DIR, exist_ok=True)
    print("目标目录: %s\n" % SERVICES_DIR)

    for a in selected:
        d = write_workflow(a, SERVICES_DIR)
        print("  [ok] %-16s -> %s" % (a["key"], os.path.relpath(d, SERVICES_DIR)))

    flush_services()
    print("\n共生成 %d 个操作,已刷新服务注册。" % len(selected))
    print("用法:在 Finder 中选中文件/文件夹 -> 右键 -> 快速操作(或直接看到操作名)")


if __name__ == "__main__":
    main()
