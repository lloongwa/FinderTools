# mac-finder-tools

给 macOS Finder 补上真正好用的右键操作：**拷贝路径、拷贝名称、新建文件、压缩为 ZIP/TAR.GZ、复制到、移动到、剪切、粘贴到此处、Git 状态、在此打开终端、用 VS Code 打开、显示/隐藏隐藏文件**。

形态是 Automator 服务（`.workflow`），装在 `~/Library/Services/`：

- 免签名、免付费开发者账号
- **零常驻进程**——只是躺在磁盘上的静态文件，只有你点它时系统才临时拉起一个进程，
  跑完即退，不占内存、不占菜单栏、无开机启动项
- **不需要「自动化」授权**——系统直接把选中文件作为 `$@` 传给脚本，脚本从不主动问 Finder

---

## 安装

```bash
cd mac-finder-tools
python3 build_services.py
```

生成 13 个 `.workflow` 到 `~/Library/Services/`，并自动刷新系统服务注册。

## 使用

在 Finder 中选中文件/文件夹 → 右键 → **服务** → 选择操作。

> 注意是「服务」子菜单，不是「快速操作」区。
> 如果看不到：先 `killall Finder`；还不行就注销重登录；
> 再到「系统设置 → 键盘 → 键盘快捷键 → 服务」确认这些项已勾选。
>
> 服务要求有传入的文件项，所以要对准**文件或文件夹**右键；
> 右键窗口空白处（无选中项）时菜单里大概率不出现。
> 对文件夹右键 = 作用于文件夹本身，对文件右键 = 作用于其所在目录（如新建文件）。

## 命令

```bash
python3 build_services.py              # 生成全部
python3 build_services.py copy_path    # 只生成某一个
python3 build_services.py --list       # 列出所有操作
python3 build_services.py --clean      # 全部删除
```

### 操作清单

| 操作 | 说明 |
|---|---|
| 拷贝路径 | 完整 POSIX 路径，多项用换行分隔 |
| 拷贝名称 | 纯文件名（不含路径） |
| 新建文件… | 弹窗输入文件名，在当前文件夹创建，冲突自动加 `-1` 后缀 |
| 压缩为 ZIP | 用 `ditto` 压缩，保留 macOS 扩展属性和资源分支 |
| 压缩为 TAR.GZ | `tar -czf` 压缩 |
| 复制到… | 弹窗选目标文件夹 |
| 移动到… | 弹窗选目标文件夹 |
| 剪切 | 标记选中项（写 cut-list），不立即移动 |
| 粘贴到此处 | 把 cut-list 里的项移动到当前文件夹 |
| Git 状态 | 把仓库/分支/改动数/领先提交数复制到剪贴板 |
| 在此打开终端 | 在 Terminal.app 打开当前目录（未装 iTerm2 时的兜底） |
| 用 VS Code 打开 | 用 Visual Studio Code 打开选中项 |
| 显示/隐藏 隐藏文件 | 切换 `AppleShowAllFiles` 并重启 Finder |

### 测试

```bash
python3 test_scripts.py
```

从生成的 `.workflow` 里提取 shell 脚本，做语法检查 + 功能冒烟测试（压缩产物、剪贴板内容、剪切粘贴移动、git 状态解析）。只测本项目生成的 13 个操作，不碰 `~/Library/Services` 里的第三方 workflow。测试会临时改写剪贴板和剪切列表，结束后自动恢复（剪贴板仅按纯文本恢复）。

需要 GUI 弹窗的操作（新建文件/复制到/移动到/打开终端/VS Code）和会重启 Finder 的操作（显示隐藏文件）只做语法检查，标注为手动验证。

## 改代码前必读：三个静默失效的坑

这三条任意一条写错，服务都会**静默失效**——没有报错、没有日志（或现象完全误导），
排查成本很高。

**1. `workflowTypeIdentifier` 必须是 `com.apple.Automator.servicesMenu`**

不能用 `quickAction`。本机所有能正常出现在 Finder 右键的 workflow
（系统自带 5 个 + 第三方 `Open in ZCode.workflow`）用的全是 `servicesMenu`，
没有一个用 `quickAction`。

**2. `NSSendFileTypes` 必须是具体 UTI**

不能用 `public.item`——它是抽象顶层类型（`conforms(to: .data) == false`），
系统不会拿它去匹配任何实际文件。当前用的是
`public.data`（覆盖所有文件）+ `public.folder` / `public.directory`（覆盖所有文件夹）。

**3. 服务上下文里 `pbcopy` 写剪贴板会「蒸发」**

服务由 `com.apple.automator.runner`（XPC）执行，这个上下文里写剪贴板，
若**写方进程立刻退出**（`pbcopy` 正是如此），写入的数据会被系统回收——
`pbcopy` 退出码 0、当场 `pbpaste` 还能读到、几秒后消失，极具迷惑性。
实测于 macOS 27.0。解法是 `SCRIPT_HEADER` 里的 `clip()`：
内容写入临时文件，用 `osascript` 读入并 `set the clipboard`，再 `delay 1.5`
让写方进程多活一会，数据才落得住。所有写剪贴板的操作必须走 `clip()`，
不得直接用 `pbcopy`。

其余约定：`document.wflow` 只写 `Contents/document.wflow` 一处（曾经两处都写，
导致 `codesign` 因同名子资源冲突失败）；不需要签名（ZCode 同样未签名也能用）。

---

## 文件结构

```
mac-finder-tools/
├── build_services.py      # 生成器:生成 13 个 .workflow
├── test_scripts.py        # 测试:脚本语法 + 功能冒烟测试
└── README.md
```

> 历史上还做过一个菜单栏常驻 App 方案（FinderToolsApp），已废弃删除。
> 废弃原因：它必须靠 AppleScript 主动询问 Finder「你选中了什么」，
> 而本机自动化授权未授予，`osascript` 一律返回 `权限违例 (-10004)`。
> 相比之下 `.workflow` 方案由系统直接把选中文件作为 `$@` 传入，不需要任何授权，
> 而且零常驻进程。旧源码可翻 git 历史第一个提交。

## 改操作逻辑

操作定义在 `build_services.py` 的 `ACTIONS` 列表。改完后：

```bash
python3 build_services.py && python3 test_scripts.py
```
