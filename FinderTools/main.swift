import AppKit

// FinderTools —— 以「提供服务」(NSServices)形态存在的 Finder 右键工具集。
//
// macOS 把用户在 Finder 里选中的文件直接递给下面的 service 方法,
// 不需要「自动化」等任何授权;无常驻进程,空闲 30 秒自动退出。
// 剪贴板/弹窗/通知全部走原生 API,不经 osascript。
//
// 调试:FinderTools --run <操作名> <路径...> 可以不弹右键直接执行某个操作。

private let fm = FileManager.default
private let stateDir = NSHomeDirectory() + "/.local/state/finder-tools"
private let cutFile = stateDir + "/cut-list"

private let gitBinary: String = {
    for c in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
        if fm.fileExists(atPath: c) { return c }
    }
    return "/usr/bin/git"
}()

// MARK: - 路径工具

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

// MARK: - 进程与通知

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

func notify(_ title: String, _ body: String) {
    let esc = { (s: String) -> String in
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    runShell(["/usr/bin/osascript", "-e",
              "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

/// 原生剪贴板写入。App 进程是正常的剪贴板客户端,不存在旧 workflow 方案里
/// XPC 上下文「写方秒退、数据被回收」的蒸发问题,写入即时生效。
func copyToPasteboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
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
        notify("Git 状态", "选中的项不在 Git 仓库中")
        return
    }
    copyToPasteboard(blocks.joined(separator: "\n\n"))
    notify("Git 状态", summary.joined(separator: " ") + " (详情已复制)")
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
            notify("FinderTools", "没有取到 Finder 选中项")
            return
        }
        switch self {
        case .copyPath:
            copyToPasteboard(paths.joined(separator: "\n"))
            notify("拷贝路径", "已复制 \(paths.count) 个路径")

        case .copyName:
            let names = paths.map { ($0 as NSString).lastPathComponent }
            copyToPasteboard(names.joined(separator: "\n"))
            notify("拷贝名称", "已复制 \(paths.count) 个文件名")

        case .newFile:
            let dir = targetDir(of: paths[0])
            guard let name = promptText(title: "新建文件",
                                        message: "在 \(dir) 中创建",
                                        defaultValue: "untitled.txt") else { return }
            let p = uniquePath(dir + "/" + name)
            try? "".write(toFile: p, atomically: true, encoding: .utf8)
            notify("新建文件", (p as NSString).lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])

        case .zip:
            let n = paths.filter { compress($0, kind: "zip") }.count
            notify("压缩为 ZIP", "完成 \(n)/\(paths.count) 项")

        case .tarGZ:
            let n = paths.filter { compress($0, kind: "tar.gz") }.count
            notify("压缩为 TAR.GZ", "完成 \(n)/\(paths.count) 项")

        case .copyTo:
            guard let dest = chooseFolder(prompt: "复制到:") else { return }
            let n = paths.filter { runShell(["/bin/cp", "-R", $0, dest]).0 == 0 }.count
            notify("复制到", "\(n)/\(paths.count) 项 → \((dest as NSString).lastPathComponent)")

        case .moveTo:
            guard let dest = chooseFolder(prompt: "移动到:") else { return }
            let n = paths.filter { runShell(["/bin/mv", $0, dest]).0 == 0 }.count
            notify("移动到", "\(n)/\(paths.count) 项 → \((dest as NSString).lastPathComponent)")

        case .cut:
            try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            try? (paths.joined(separator: "\n") + "\n")
                .write(toFile: cutFile, atomically: true, encoding: .utf8)
            notify("剪切", "已标记 \(paths.count) 项,再点「粘贴到此处」")

        case .pasteHere:
            let content = (try? String(contentsOfFile: cutFile, encoding: .utf8)) ?? ""
            let items = content.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && fm.fileExists(atPath: $0) }
            guard !items.isEmpty else {
                notify("粘贴到此处", "没有待剪切的项")
                return
            }
            let dest = targetDir(of: paths[0])
            let n = items.filter { runShell(["/bin/mv", $0, dest]).0 == 0 }.count
            try? "".write(toFile: cutFile, atomically: true, encoding: .utf8)
            notify("粘贴到此处", "已移动 \(n)/\(items.count) 项 → \((dest as NSString).lastPathComponent)")

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
            notify("隐藏文件",
                   currentlyShown ? "已隐藏(Finder 已重启)" : "已显示(Finder 已重启)")
        }
    }
}

// MARK: - 服务入口

final class ServiceProvider: NSObject {
    @objc func copyPath(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.copyPath, pboard) }
    @objc func copyName(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.copyName, pboard) }
    @objc func newFile(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.newFile, pboard) }
    @objc func compressZip(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.zip, pboard) }
    @objc func compressTarGz(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.tarGZ, pboard) }
    @objc func copyTo(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.copyTo, pboard) }
    @objc func moveTo(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.moveTo, pboard) }
    @objc func cut(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.cut, pboard) }
    @objc func paste(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.pasteHere, pboard) }
    @objc func gitStatus(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.gitStatus, pboard) }
    @objc func openTerminal(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.terminal, pboard) }
    @objc func openVscode(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.vscode, pboard) }
    @objc func toggleHidden(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) { handle(.toggleHidden, pboard) }

    private func handle(_ action: ItemAction, _ pboard: NSPasteboard) {
        busy = true
        defer {
            busy = false
            scheduleQuit()
        }
        // 系统按 Info.plist 里的 NSSendFileTypes 过滤后,把选中的文件 URL 放进剪贴板递过来
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        action.run(urls.map { normalizePath($0.path) })
    }
}

// MARK: - 空闲自退出

private var quitWorkItem: DispatchWorkItem?
private var busy = false

/// 空闲 30 秒后退出,保持「零常驻」;连续操作时计时自动顺延
func scheduleQuit() {
    quitWorkItem?.cancel()
    let w = DispatchWorkItem {
        if busy {
            scheduleQuit()
            return
        }
        NSApp.terminate(nil)
    }
    quitWorkItem = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
}

// MARK: - 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = ServiceProvider()

        // 调试模式:FinderTools --run <操作名> <路径...>
        // 不经过右键直接执行操作,供 selftest 和手工排障使用
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--run"), i + 1 < args.count {
            if let action = ItemAction(rawValue: args[i + 1]) {
                action.run(Array(args[(i + 2)...]))
            } else {
                FileHandle.standardError.write("未知操作: \(args[i + 1])\n可用操作: \(ItemAction.allCases.map { $0.rawValue }.joined(separator: " / "))\n".data(using: .utf8)!)
            }
            exit(0)
        }

        scheduleQuit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
