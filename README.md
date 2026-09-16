# mac-finder-tools

给 macOS Finder 补上真正好用的右键操作：**拷贝路径、拷贝名称、新建文件、压缩为 ZIP/TAR.GZ、复制到、移动到、剪切、粘贴到此处、Git 状态、在此打开终端、用 VS Code 打开、显示/隐藏隐藏文件**。

形态是一个「提供服务」的小 App（`FinderTools.app`，声明 `NSServices`）：

- **零授权**——系统把 Finder 里选中的文件直接递给 App，不需要「自动化」等任何权限
- **零常驻**——右键点击时才被系统拉起，空闲 30 秒自动退出，不占内存、无开机启动项
- **原生 API**——剪贴板/弹窗/通知全部走 AppKit，不经 `osascript` 拼字符串

---

## 安装

**方式一：自己编译（推荐）**

```bash
cd mac-finder-tools/FinderTools
bash build.sh install
```

只需要免费的 [Xcode Command Line Tools](https://developer.apple.com/download/all/)（`xcode-select --install`），
**不需要 Python、不需要完整 Xcode**。脚本会：编译 universal2 二进制 → ad-hoc 签名 →
装入 `~/Applications/FinderTools.app` → 移除旧版 13 个 `.workflow`（如果有，避免菜单重复）→ 刷新系统服务注册。

**方式二：直接用编译好的 App（给别人用）**

把 `FinderTools.app` 拖进 `~/Applications`（或 `/Applications`）即可。
App 未经过公证（公证需要付费开发者账号），首次运行若被 Gatekeeper 拦下，
在终端执行 `xattr -dr com.apple.quarantine ~/Applications/FinderTools.app` 即可。

> 看不到右键菜单时：先 `killall Finder`；还不行就注销重登录；
> 再到「系统设置 → 键盘 → 键盘快捷键 → 服务」确认这些项已勾选。

## 使用

在 Finder 中选中文件/文件夹 → 右键 → **服务** → 选择操作。

> 服务要求有传入的文件项，要对准**文件或文件夹**右键；右键窗口空白处（无选中项）不出现。
> 对文件夹右键 = 作用于文件夹本身，对文件右键 = 作用于其所在目录（如新建文件）。

## 操作清单

| 操作 | 说明 |
|---|---|
| 拷贝路径 | 完整 POSIX 路径，多项用换行分隔，原生写入剪贴板即时生效 |
| 拷贝名称 | 纯文件名（不含路径） |
| 新建文件… | 原生弹窗输入文件名，在当前文件夹创建，冲突自动加 `-1` 后缀，创建后在 Finder 中高亮 |
| 压缩为 ZIP | 用 `ditto` 压缩，保留 macOS 扩展属性和资源分支 |
| 压缩为 TAR.GZ | `tar -czf` 压缩 |
| 复制到… | 原生文件夹选择面板 |
| 移动到… | 同上 |
| 剪切 | 标记选中项（写 cut-list），不立即移动 |
| 粘贴到此处 | 把 cut-list 里的项移动到当前文件夹 |
| Git 状态 | 把仓库/分支/改动数/领先提交数复制到剪贴板 |
| 在此打开终端 | 在 Terminal.app 打开当前目录 |
| 用 VS Code 打开 | 用 Visual Studio Code 打开选中项 |
| 显示/隐藏 隐藏文件 | 切换 `AppleShowAllFiles` 并重启 Finder |

## 测试

```bash
bash FinderTools/build.sh selftest
```

通过 App 的 `--run` 调试模式（`FinderTools --run <操作名> <路径...>`，可不经右键直接执行操作）
做冒烟测试：剪贴板写入与持久性、多文件名、压缩产物、剪切粘贴、git 状态解析、空参数防御。

## 为什么是这个形态

三种候选方案里，这是唯一同时满足「零授权 + 零常驻」的：

| | workflow 服务（legacy） | 菜单栏常驻 App | **提供 Services 的 App（本方案）** |
|---|---|---|---|
| 拿到 Finder 选中项 | 系统传入 `$@`，零授权 | 必须 AppleScript 问 Finder，要「自动化」授权 | 系统递文件 URL 给 App，零授权 |
| 常驻进程 | 无 | 有 | 无（按需拉起，空闲自退） |
| 剪贴板/弹窗 | osascript 拼 AppleScript | 原生 | 原生 |

菜单栏 App 方案在本机实测 `osascript` 访问 Finder 一律返回 `权限违例 (-10004)`，已废弃。

## 开源给别人用

- **使用者**：拿到 `FinderTools.app` 拖进 `~/Applications` 就能跑。运行时零依赖——不需要 Python、不需要 Xcode、任何版本 macOS 13+（Intel/Apple Silicon）都行。
- **想自己编译**：装好 Xcode Command Line Tools 后 `bash FinderTools/build.sh install`，全程不需要 Python。
- 欢迎基于它增删自己的服务：在 `FinderTools/Info.plist` 的 `NSServices` 数组里加一项，
  在 `main.swift` 的 `ServiceProvider` 加对应 `@objc` 方法、`ItemAction` 加一个 case，`bash build.sh install` 即可。

---

## legacy/（旧 workflow 方案，已被 App 方案取代）

`build_services.py` 生成 13 个 Automator `.workflow` 装进 `~/Library/Services/`，
`test_scripts.py` 对其做冒烟测试。保留作参考；若要回退：

```bash
python3 legacy/build_services.py        # 重新生成 workflow 服务
```

该方案留下三条宝贵的坑记录（原文见 `legacy/build_services.py` 内注释）：

1. **`workflowTypeIdentifier` 必须是 `com.apple.Automator.servicesMenu`**，用 `quickAction` 服务静默不出现。
2. **`NSSendFileTypes` 必须是具体 UTI**，`public.item` 是抽象顶层类型，系统不会拿它匹配任何文件（本方案的 Info.plist 同样遵守这条）。
3. **服务 XPC 上下文里 `pbcopy` 写剪贴板会「蒸发」**（macOS 27.0 实测）：写方进程立刻退出则数据被系统回收——退出码 0、当场可读、数秒后消失。当时用「osascript 写入 + delay 1.5 秒」绕过；App 方案跑在正常进程上下文，此坑天然不存在，剪贴板写入即时生效。
