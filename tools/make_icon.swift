// make_icon.swift — 用 AppKit 画 App 图标并导出各尺寸 PNG（供 iconutil 打包 .icns）
import AppKit

func makeIcon(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // 透明底 + 圆角渐变方块
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: s, height: s).fill()
    let inset = s * 0.045
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.60, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.56, blue: 0.90, alpha: 1)
    ])!
    grad.draw(in: path, angle: -90)

    // 屏幕
    let screen = NSBezierPath(roundedRect: NSRect(x: s * 0.21, y: s * 0.70,
                                                  width: s * 0.58, height: s * 0.17),
                              xRadius: s * 0.028, yRadius: s * 0.028)
    NSColor.white.withAlphaComponent(0.22).setFill()
    screen.fill()

    // 点击轮
    let cx = s * 0.5
    let cy = s * 0.40
    let rOuter = s * 0.255
    let ring = NSBezierPath(ovalIn: NSRect(x: cx - rOuter, y: cy - rOuter,
                                           width: rOuter * 2, height: rOuter * 2))
    ring.lineWidth = max(1.2, s * 0.030)
    NSColor.white.withAlphaComponent(0.96).setStroke()
    ring.stroke()

    // 中间按钮 + 播放三角
    let rIn = s * 0.092
    let inner = NSBezierPath(ovalIn: NSRect(x: cx - rIn, y: cy - rIn,
                                            width: rIn * 2, height: rIn * 2))
    NSColor.white.setFill()
    inner.fill()

    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: cx - s * 0.030, y: cy - s * 0.048))
    tri.line(to: NSPoint(x: cx + s * 0.048, y: cy))
    tri.line(to: NSPoint(x: cx - s * 0.030, y: cy + s * 0.048))
    tri.close()
    NSColor(calibratedRed: 0.02, green: 0.30, blue: 0.62, alpha: 1).setFill()
    tri.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]) ?? Data()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, sz) in specs {
    let data = makeIcon(size: sz)
    if !data.isEmpty {
        try? data.write(to: URL(fileURLWithPath: outDir + "/" + name))
    }
}
print("icons written to \(outDir)")
