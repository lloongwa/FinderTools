#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从生成的 .workflow 中提取 shell 脚本,做语法检查 + 功能冒烟测试。

自动化测试无法覆盖需要 GUI 交互的操作(新建文件/复制到/移动到/打开终端/VS Code),
这些只做语法检查,标注为需要手动验证。

测试会临时改写剪贴板和 cut-list,结束后恢复原内容(注:剪贴板只按纯文本恢复,
若原内容是图片等非文本数据,恢复后会变成空文本)。

用法:
    python3 test_scripts.py
"""

import os
import plistlib
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_services import ACTIONS

SERVICES_DIR = os.path.expanduser("~/Library/Services")
TEST_ROOT = "/tmp/finder-tools-test"
CUT_LIST = os.path.expanduser("~/.local/state/finder-tools/cut-list")

# 只测本项目生成的操作,不碰 ~/Library/Services 里的第三方 workflow
PROJECT_KEYS = {a["key"] for a in ACTIONS}

# 需要 GUI 交互,只做语法检查
INTERACTIVE = {"new_file", "copy_to", "move_to", "open_terminal", "open_vscode"}
# 会重启 Finder,不自动执行
DESTRUCTIVE = {"toggle_hidden"}


def load_script(key):
    p = os.path.join(SERVICES_DIR, "%s.workflow" % key, "Contents", "document.wflow")
    with open(p, "rb") as f:
        doc = plistlib.load(f)
    return doc["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"]


def syntax_check(script):
    r = subprocess.run(["/bin/bash", "-n"], input=script, text=True,
                       capture_output=True)
    return (r.returncode == 0), r.stderr.strip()


def run_script(script, args, timeout=60):
    return subprocess.run(["/bin/bash", "-c", script, "_"] + args,
                          capture_output=True, text=True, timeout=timeout)


def setup_fixtures():
    """准备测试文件"""
    if os.path.exists(TEST_ROOT):
        shutil.rmtree(TEST_ROOT)
    os.makedirs(TEST_ROOT)

    f1 = os.path.join(TEST_ROOT, "demo.txt")
    with open(f1, "w") as f:
        f.write("hello\n")

    sub = os.path.join(TEST_ROOT, "subdir")
    os.makedirs(sub)
    with open(os.path.join(sub, "inner.md"), "w") as f:
        f.write("# inner\n")

    # git 仓库,含一个未跟踪文件
    repo = os.path.join(TEST_ROOT, "repo")
    os.makedirs(repo)
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
    with open(os.path.join(repo, "tracked.txt"), "w") as f:
        f.write("v1\n")
    subprocess.run(["git", "-C", repo, "add", "."], check=True, env=env)
    subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "init"],
                   check=True, env=env)
    with open(os.path.join(repo, "untracked.txt"), "w") as f:
        f.write("new\n")
    with open(os.path.join(repo, "tracked.txt"), "w") as f:
        f.write("v2\n")

    return {"file": f1, "dir": sub, "repo": repo, "root": TEST_ROOT}


def get_clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def set_clipboard(s):
    subprocess.run(["pbcopy"], input=s, text=True)


def save_state():
    """备份测试将要改写的用户状态:剪贴板文本与 cut-list"""
    clip = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
    cut = None
    if os.path.exists(CUT_LIST):
        with open(CUT_LIST, encoding="utf-8") as f:
            cut = f.read()
    return clip, cut


def restore_state(clip, cut):
    subprocess.run(["pbcopy"], input=clip, text=True)
    if cut is None:
        if os.path.exists(CUT_LIST):
            os.remove(CUT_LIST)
    else:
        os.makedirs(os.path.dirname(CUT_LIST), exist_ok=True)
        with open(CUT_LIST, "w", encoding="utf-8") as f:
            f.write(cut)


def run_tests():
    keys = sorted(
        d[:-len(".workflow")]
        for d in os.listdir(SERVICES_DIR)
        if d.endswith(".workflow") and d[:-len(".workflow")] in PROJECT_KEYS
    )
    if not keys:
        print("~/Library/Services 下没有本项目的操作,先运行 python3 build_services.py")
        return 1

    print("=" * 60)
    print("1. 语法检查")
    print("=" * 60)
    scripts = {}
    bad = []
    for k in keys:
        try:
            s = load_script(k)
        except Exception as e:
            print("  [FAIL] %-16s 读取失败: %s" % (k, e))
            bad.append(k)
            continue
        scripts[k] = s
        ok, err = syntax_check(s)
        if ok:
            print("  [ok]   %-16s 语法正确" % k)
        else:
            print("  [FAIL] %-16s %s" % (k, err))
            bad.append(k)

    fx = setup_fixtures()
    print("\n测试夹具: %s" % TEST_ROOT)
    print("  file=%s\n  dir=%s\n  repo=%s" % (fx["file"], fx["dir"], fx["repo"]))

    results = []

    def check(name, cond, detail=""):
        results.append((name, cond, detail))
        print("  [%s] %-16s %s" % ("ok" if cond else "FAIL", name, detail))

    print("\n" + "=" * 60)
    print("2. 功能测试")
    print("=" * 60)

    # --- copy_path ---
    if "copy_path" in scripts:
        set_clipboard("")
        r = run_script(scripts["copy_path"], [fx["file"]])
        check("copy_path", get_clipboard() == fx["file"],
              "clipboard=%r stderr=%s" % (get_clipboard(), r.stderr.strip()[:80]))

    # --- copy_name ---
    if "copy_name" in scripts:
        set_clipboard("")
        r = run_script(scripts["copy_name"], [fx["file"]])
        check("copy_name", get_clipboard() == "demo.txt",
              "clipboard=%r" % get_clipboard())

    # --- compress_zip ---
    if "compress_zip" in scripts:
        r = run_script(scripts["compress_zip"], [fx["dir"]])
        zp = fx["dir"] + ".zip"
        check("compress_zip", os.path.isfile(zp),
              "exists=%s stderr=%s" % (os.path.isfile(zp), r.stderr.strip()[:80]))
        if os.path.isfile(zp):
            v = subprocess.run(["unzip", "-l", zp], capture_output=True, text=True)
            check("compress_zip 内容", "inner.md" in v.stdout,
                  "size=%d" % os.path.getsize(zp))

    # --- compress_targz ---
    if "compress_targz" in scripts:
        r = run_script(scripts["compress_targz"], [fx["dir"]])
        tp = fx["dir"] + ".tar.gz"
        check("compress_targz", os.path.isfile(tp),
              "exists=%s stderr=%s" % (os.path.isfile(tp), r.stderr.strip()[:80]))
        if os.path.isfile(tp):
            v = subprocess.run(["tar", "-tzf", tp], capture_output=True, text=True)
            check("compress_targz 内容", "inner.md" in v.stdout, "")

    # --- cut + paste_cut ---
    if "cut" in scripts and "paste_cut" in scripts:
        dest = os.path.join(TEST_ROOT, "dest")
        os.makedirs(dest)
        src = os.path.join(TEST_ROOT, "movable.txt")
        with open(src, "w") as f:
            f.write("move me\n")
        r1 = run_script(scripts["cut"], [src])
        marked = os.path.exists(os.path.expanduser(
            "~/.local/state/finder-tools/cut-list"))
        r2 = run_script(scripts["paste_cut"], [dest])
        moved = os.path.isfile(os.path.join(dest, "movable.txt"))
        check("cut 标记", marked, "cut-list 已创建")
        check("paste_cut 移动", moved and not os.path.exists(src),
              "moved=%s 原位置已移除=%s" % (moved, not os.path.exists(src)))

    # --- git_status ---
    if "git_status" in scripts:
        set_clipboard("")
        r = run_script(scripts["git_status"], [fx["repo"]])
        cb = get_clipboard()
        check("git_status", "branch: main" in cb and "changed: 2" in cb,
              "clipboard first line=%r" % cb.split("\n")[0] if cb else "empty")

    # --- 交互/破坏性操作 ---
    print("\n" + "=" * 60)
    print("3. 需手动验证(涉及 GUI 交互或重启 Finder)")
    print("=" * 60)
    for k in keys:
        if k in INTERACTIVE:
            print("  [手动] %-16s 需要 GUI 弹窗/打开 App" % k)
        elif k in DESTRUCTIVE:
            print("  [手动] %-16s 会重启 Finder,未自动执行" % k)

    print("\n" + "=" * 60)
    failed = [n for n, c, _ in results if not c] + bad
    if failed:
        print("失败项: %s" % ", ".join(failed))
        return 1
    print("全部自动测试通过 (%d 项)" % len(results))
    return 0


if __name__ == "__main__":
    clip, cut = save_state()
    try:
        sys.exit(run_tests())
    finally:
        restore_state(clip, cut)
