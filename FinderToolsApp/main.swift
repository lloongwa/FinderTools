import AppKit
import Foundation

// MARK: - 常量与工具

private let fm = FileManager.default

private let stateDir: String = {
    let d = NSHomeDirectory() + "/.local/state/finder-tools"
    try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}()

/// 与 A 方案(.workflow 快速操作)共享同一个剪切列表
private let cutFile = stateDir + "/cut-list"

private let gitBinary: String = {
    for c in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
        if fm.fileExists(atPath: c) { return c }
    }
    return "/usr/bin/git"
}()

func normalizePath(_ p: String) -> String {
    var s = p
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}

/// 路径是目录则返回自身,否则返回其所在目录
func targetDir(of path: String) -> String {
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        return normalizePath(path)
    }
    return (path as NSString).deletingLastPathComponent
}

/// 目标已存在时追加 -1 / -2 … 后缀
func uniquePath(_ p: String) -> String {
    guard fm.fileExists(atPath: p) else { return p }
    let ns = p as NSString
    let dir = ns.deletingLastPathComponent
    let name = ns.lastPathComponent
    let ext = ns.pathExtension
    let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    var i = 1
    while true {
        let cand = ext.isEmpty ? "\(dir)/\(base)-\(i)" : "\(dir)/\(base)-\(i).\(ext)"
        if !fm.fileExists(atPath: cand) { return cand }
        i += 1
    }
}

@discardableResult
func runShell(_ args: [String], cwd: String? = nil) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" +
        (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    p.environment = env
    let so = Pipe()
    let se = Pipe()
    p.standardOutput = so
    p.standardError = se
    do {
        try p.run()
    } catch {
        return (-1, "", error.localizedDescription)
    }
    let od = so.fileHandleForReading.readDataToEndOfFile()
    let ed = se.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: od, as: UTF8.self),
            String(decoding: ed, as: UTF8.self))
}

func sendNotification(_ title: String, _ body: String) {
    let esc = { (s: String) -> String in
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    runShell(["/usr/bin/osascript", "-e",
              "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

/// 读取 Finder 当前选中项;未选中任何东西时回退为当前窗口所在文件夹
func finderSelection() -> [String] {
    let src = """
    tell application "Finder"
        set selList to (get selection)
        if (count of selList) > 0 then
            set outText to ""
            repeat with s in selList
                set outText to outText & (POSIX path of (s as alias)) & linefeed
            end repeat
            return outText
        else
            try
                return POSIX path of ((target of front window) as alias)
            on error
                return POSIX path of (path to desktop folder)
            end try
        end if
    end tell
    """
    var err: NSDictionary?
    guard let sc = NSAppleScript(source: src) else { return [] }
    let out = sc.executeAndReturnError(&err)
    guard let text = out.stringValue else { return [] }
    return text.split(separator: "\n")
        .map { normalizePath(String($0)) }
        .filter { !$0.isEmpty }
}

// MARK: - 弹窗(必须在主线程调用)

func promptText(title: String, message: String, defaultValue: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    tf.stringValue = defaultValue
    alert.accessoryView = tf
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = tf
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let v = tf.stringValue.trimmingCharacters(in: .whitespaces)
    return v.isEmpty ? nil : v
}

func chooseFolder(prompt: String) -> String? {
    let panel = NSOpenPanel()
    panel.message = prompt
    panel.prompt = "选择"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let u = panel.url else { return nil }
    return normalizePath(u.path)
}

// MARK: - 具体操作

func compress(_ path: String, kind: String) -> Bool {
    let ns = path as NSString
    let dir = ns.deletingLastPathComponent
    let name = ns.lastPathComponent
    let out = uniquePath("\(dir)/\(name).\(kind)")
    if kind == "zip" {
        // ditto 保留 macOS 扩展属性与资源分支,比 zip 更适合 Finder 场景
        return runShell(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc",
                         "--keepParent", name, (out as NSString).lastPathComponent],
                        cwd: dir).0 == 0
    }
    return runShell(["/usr/bin/tar", "-czf", out, "-C", dir, name]).0 == 0
}

func runGitStatus(_ paths: [String]) {
    var blocks: [String] = []
    var summary: [String] = []
    for f in paths {
        let d = targetDir(of: f)
        let repo = runShell([gitBinary, "rev-parse", "--show-toplevel"], cwd: d).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if repo.isEmpty { continue }
        let br = runShell([gitBinary, "rev-parse", "--abbrev-ref", "HEAD"], cwd: repo).1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let st = runShell([gitBinary, "status", "--porcelain"], cwd: repo).1
        let cnt = st.split(separator: "\n").count
        let ahead = runShell([gitBinary, "rev-list", "--count", "@{upstream}..HEAD"],
                             cwd: repo).1.trimmingCharacters(in: .whitespacesAndNewlines)
        blocks.append("repo:    \(repo)\nbranch:  \(br)\nchanged: \(cnt) files\nahead:   \(ahead.isEmpty ? "?" : ahead) commit(s)")
        summary.append("\((repo as NSString).lastPathComponent)[\(br):\(cnt)]")
    }
    if blocks.isEmpty {
        sendNotification("Git 状态", "选中的项不在 Git 仓库中")
        return
    }
    copyToPasteboard(blocks.joined(separator: "\n\n"))
    sendNotification("Git 状态", summary.joined(separator: " ") + " (详情已复制)")
}

enum ItemAction: String, CaseIterable {
    case copyPath = "拷贝路径"
    case copyName = "拷贝名称"
    case newFile = "新建文件…"
    case zip = "压缩为 ZIP"
    case tarGZ = "压缩为 TAR.GZ"
    case copyTo = "复制到…"
    case moveTo = "移动到…"
    case cut = "剪切"
    case pasteHere = "粘贴到此处"
    case gitStatus = "Git 状态"
    case terminal = "在此打开终端"
    case vscode = "用 VS Code 打开"
    case toggleHidden = "显示/隐藏 隐藏文件"

    func run(_ paths: [String]) {
        guard !paths.isEmpty else {
            sendNotification("FinderTools", "没有取到 Finder 选中项")
            return
        }
        switch self {
        case .copyPath:
            copyToPasteboard(paths.joined(separator: "\n"))
            sendNotification("拷贝路径", "已复制 \(paths.count) 个路径")

        case .copyName:
            let names = paths.map { ($0 as NSString).lastPathComponent }
            copyToPasteboard(names.joined(separator: "\n"))
            sendNotification("拷贝名称", "已复制 \(paths.count) 个文件名")

        case .newFile:
            let dir = targetDir(of: paths[0])
            guard let name = promptText(title: "新建文件",
                                        message: "在 \(dir) 中创建",
                                        defaultValue: "untitled.txt") else { return }
            let p = uniquePath(dir + "/" + name)
            fm.createFile(atPath: p, contents: nil)
            sendNotification("新建文件", (p as NSString).lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])

        case .zip:
            let n = paths.filter { compress($0, kind: "zip") }.count
            sendNotification("压缩为 ZIP", "完成 \(n)/\(paths.count) 项")

        case .tarGZ:
            let n = paths.filter { compress($0, kind: "tar.gz") }.count
            sendNotification("压缩为 TAR.GZ", "完成 \(n)/\(paths.count) 项")

        case .copyTo:
            guard let dest = chooseFolder(prompt: "复制到:") else { return }
            let n = paths.filter { runShell(["/bin/cp", "-R", $0, dest]).0 == 0 }.count
            sendNotification("复制到", "\(n)/\(paths.count) 项 → \((dest as NSString).lastPathComponent)")

        case .moveTo:
            guard let dest = chooseFolder(prompt: "移动到:") else { return }
            let n = paths.filter { runShell(["/bin/mv", $0, dest]).0 == 0 }.count
            sendNotification("移动到", "\(n)/\(paths.count) 项 → \((dest as NSString).lastPathComponent)")

        case .cut:
            try? (paths.joined(separator: "\n") + "\n")
                .write(toFile: cutFile, atomically: true, encoding: .utf8)
            sendNotification("剪切", "已标记 \(paths.count) 项,再点「粘贴到此处」")

        case .pasteHere:
            let content = (try? String(contentsOfFile: cutFile, encoding: .utf8)) ?? ""
            let items = content.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && fm.fileExists(atPath: $0) }
            guard !items.isEmpty else {
                sendNotification("粘贴到此处", "没有待剪切的项")
                return
            }
            let dest = targetDir(of: paths[0])
            let n = items.filter { runShell(["/bin/mv", $0, dest]).0 == 0 }.count
            try? "".write(toFile: cutFile, atomically: true, encoding: .utf8)
            sendNotification("粘贴到此处", "已移动 \(n)/\(items.count) 项 → \((dest as NSString).lastPathComponent)")

        case .gitStatus:
            runGitStatus(paths)

        case .terminal:
            for f in paths {
                runShell(["/usr/bin/open", "-a", "Terminal", targetDir(of: f)])
            }

        case .vscode:
            runShell(["/usr/bin/open", "-a", "Visual Studio Code"] + paths)

        case .toggleHidden:
            let cur = runShell(["/usr/bin/defaults", "read",
                                "com.apple.finder", "AppleShowAllFiles"]).1
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentlyShown = (cur == "1" || cur == "true")
            runShell(["/usr/bin/defaults", "write", "com.apple.finder",
                      "AppleShowAllFiles", "-bool", currentlyShown ? "false" : "true"])
            runShell(["/usr/bin/killall", "Finder"])
            sendNotification("隐藏文件",
                             currentlyShown ? "已隐藏(Finder 已重启)" : "已显示(Finder 已重启)")
        }
    }
}

// MARK: - 菜单栏

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "folder.badge.gearshape",
                                 accessibilityDescription: "FinderTools") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "FT"
            }
            btn.toolTip = "FinderTools — 对 Finder 选中项执行操作"
        }
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = finderSelection()

        let header = NSMenuItem(title: headerTitle(paths), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        for a in ItemAction.allCases {
            let item = NSMenuItem(title: a.rawValue, action: #selector(runAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = a.rawValue as NSString
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func headerTitle(_ paths: [String]) -> String {
        if paths.isEmpty { return "未取到 Finder 选中项" }
        let first = (paths[0] as NSString).lastPathComponent
        let name = first.isEmpty ? paths[0] : first
        return paths.count == 1 ? name : "\(name) 等 \(paths.count) 项"
    }

    @objc func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = ItemAction(rawValue: raw) else { return }
        let paths = finderSelection()
        DispatchQueue.main.async { action.run(paths) }
    }

    @objc func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
