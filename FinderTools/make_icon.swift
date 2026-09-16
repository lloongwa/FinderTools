import AppKit

// 生成 FinderTools 的应用图标:macOS 风格圆角渐变底 + 白色「文件夹+齿轮」符号
// 用法: swift make_icon.swift <输出 iconset 目录>
// 生成 PNG 后用 iconutil -c icns 转换(见 build.sh)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角方块背景(沿用 macOS 图标模板的 824/1024 内缩比例)
let inset: CGFloat = 100
let bgRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.15, green: 0.40, blue: 0.92, alpha: 1),
])!.draw(in: bg, angle: -90)

// 顶部高光与细描边,增加质感
NSColor(white: 1.0, alpha: 0.22).setStroke()
bg.lineWidth = 6
bg.stroke()

// 白色「文件夹+齿轮」符号(与应用内原菜单栏图标同款意象)
let symbol = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 470, weight: .regular))!
let tinted = NSImage(size: symbol.size)
tinted.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
NSColor.white.set()
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
tinted.unlockFocus()

let s = tinted.size
let scale = 600.0 / max(s.width, s.height)
let w = s.width * scale, h = s.height * scale
tinted.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2 + 10, width: w, height: h))

image.unlockFocus()

// 输出 1024 PNG
var rect = NSRect(x: 0, y: 0, width: size, height: size)
guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
      let rep = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
else { fatalError("渲染失败") }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.write(to: URL(fileURLWithPath: out))
print("已生成 \(out)")
