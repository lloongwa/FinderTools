# legacy —— 旧版 workflow 服务方案(已被 App 方案取代)

本目录是项目早期的实现:用 Python 生成 13 个 Automator `.workflow` 服务包装进
`~/Library/Services/`,由系统按服务机制执行内嵌的 bash 脚本。

App 方案(`../FinderTools`)与之相比:同样的零授权、零常驻,但跑在正常 App
进程上下文里,剪贴板/弹窗/通知全部原生 API,没有下文第 3 条坑,拷贝也不再需要
1.5 秒延迟,因此被取代。

## 回退使用

```bash
python3 legacy/build_services.py        # 生成 13 个 workflow 到 ~/Library/Services
python3 legacy/build_services.py --clean  # 全部移除
python3 legacy/test_scripts.py          # 冒烟测试
```

注意:App 版和 workflow 版同时安装会右键菜单重复,二选一。

## 这套方案留下三条宝贵的坑记录

前两条对任何手工构造 Automator workflow 的人都适用(本项目的 Info.plist 同样遵守):

**1. `workflowTypeIdentifier` 必须是 `com.apple.Automator.servicesMenu`**

不能用 `quickAction`。本机所有能正常出现在 Finder 右键的 workflow
(系统自带 5 个 + 第三方 `Open in ZCode.workflow`)用的全是 `servicesMenu`,
用 `quickAction` 服务静默不出现在菜单里——无报错、无日志。

**2. `NSSendFileTypes` 必须是具体 UTI**

不能用 `public.item`——它是抽象顶层类型(`conforms(to: .data) == false`),
系统不会拿它去匹配任何实际文件。有效组合:
`public.data`(所有文件)+ `public.folder` / `public.directory`(所有文件夹)。

**3. 服务 XPC 上下文里 `pbcopy` 写剪贴板会「蒸发」(macOS 27.0 实测)**

服务由 `com.apple.automator.runner`(XPC)执行,这个上下文里写剪贴板,若
**写方进程立刻退出**(`pbcopy` 正是如此),写入的数据会被系统回收。现象极具
迷惑性:`pbcopy` 退出码 0、写完当场 `pbpaste` 还能读到、几秒后消失。

当时的绕过方案(见 `build_services.py` 的 `SCRIPT_HEADER.clip()`):内容写入
临时文件,`osascript` 读入并 `set the clipboard`,再 `delay 1.5` 让写方进程
多活一会,数据才落得住。四种候选(osascript / pbcopy / osascript+delay /
launchd 逃逸)实测只有加 delay 的方案能持久。
