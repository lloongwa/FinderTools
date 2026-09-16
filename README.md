# FinderTools

给 macOS Finder 右键菜单加 13 个实用操作的小工具。

一个不到 1 MB 的 App:右键点击时才被系统拉起,空闲 30 秒自动退出;不申请任何权限,不驻留后台。

## 安装

1. 从 [Releases](https://github.com/lloongwa/FinderTools/releases/latest) 下载 `FinderTools-x.x.x.dmg` 并打开
2. 把 **FinderTools.app** 拖进 **Applications**
3. 首次打开若提示无法验证开发者,终端执行:

```bash
xattr -dr com.apple.quarantine ~/Applications/FinderTools.app
```

装完即用。若右键菜单里没看到新操作,先执行 `killall Finder`。

## 功能

右键文件或文件夹 → **服务** → 选择操作:

| 操作 | 说明 |
|---|---|
| 拷贝路径 | 完整 POSIX 路径,多选用换行分隔 |
| 拷贝名称 | 仅文件名 |
| 新建文件… | 在当前文件夹创建,重名自动加 `-1` 后缀 |
| 压缩为 ZIP / TAR.GZ | ZIP 用 `ditto`,保留 macOS 扩展属性 |
| 复制到… / 移动到… | 弹出文件夹选择框 |
| 剪切 / 粘贴到此处 | 先标记,到目标文件夹再粘贴,补上 Finder 缺失的剪切 |
| Git 状态 | 仓库、分支、改动数、领先提交数,复制到剪贴板 |
| 在此打开终端 | 在当前目录打开 Terminal |
| 用 VS Code 打开 | — |
| 显示/隐藏 隐藏文件 | 切换后自动重启 Finder |

> 对**文件夹**右键,操作作用于该文件夹;对**文件**右键,操作作用于其所在目录(如新建文件)。

## 特性

- **不申请任何权限** —— 服务机制由系统直接把选中的文件递给 App,无需「自动化」「辅助功能」授权
- **无常驻进程** —— 按需拉起、空闲自退,没有开机启动项,不占菜单栏
- **全原生** —— 剪贴板即时生效,弹窗、文件夹选择、通知都是系统原生界面
- macOS 13+,Apple Silicon / Intel 通用

## 常见问题

**右键菜单里没有这些操作?**

依次尝试:`killall Finder` → 注销重新登录 → 「系统设置 → 键盘 → 键盘快捷键 → 服务…」里勾选 FinderTools 相关项。

## 自己编译

只需要免费的 Xcode Command Line Tools:

```bash
xcode-select --install        # 仅首次需要
git clone https://github.com/lloongwa/FinderTools.git
cd FinderTools/FinderTools
bash build.sh install         # 编译 + 安装 + 刷新服务注册
```

不需要 Python、不需要完整 Xcode。其他命令:`bash build.sh selftest` 跑冒烟测试,`uninstall` 卸载,`dmg` 打安装包。

## 加一个自己的操作

1. `FinderTools/Info.plist` 的 `NSServices` 数组里加一项(菜单名 + 方法名)
2. `main.swift` 的 `ServiceProvider` 里加对应的 `@objc` 方法
3. `ItemAction` 里写逻辑,然后 `bash build.sh install`

## 许可证

[MIT](LICENSE)
