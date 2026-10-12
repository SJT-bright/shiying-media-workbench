import AppKit

// 拾影桌面图标。石墨圆角底，青/玫红轻微错位边缘，白色视频框和播放三角为主体，右下角向下箭头。
// 图形必须落在圆角之内，播放三角不压住箭头。输出 PNG 同时给 icns 和侧栏 ShiyingBrand.png。

let canvas = 1024
guard CommandLine.arguments.count > 1 else {
    fputs("usage: icon.swift output.png\n", stderr)
    exit(1)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("bitmap failed\n", stderr)
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bounds = NSRect(x: 0, y: 0, width: canvas, height: canvas)
NSColor.clear.setFill()
bounds.fill(using: .copy)

let cyan = NSColor(calibratedRed: 0.145, green: 0.957, blue: 0.933, alpha: 1)
let rose = NSColor(calibratedRed: 0.996, green: 0.173, blue: 0.333, alpha: 1)
let plate = CGFloat(912)
let plateRadius = CGFloat(208)
cyan.setFill()
NSBezierPath(roundedRect: NSRect(x: 30, y: 78, width: plate, height: plate), xRadius: plateRadius, yRadius: plateRadius).fill()
rose.setFill()
NSBezierPath(roundedRect: NSRect(x: 82, y: 30, width: plate, height: plate), xRadius: plateRadius, yRadius: plateRadius).fill()

let bodyRect = NSRect(x: 56, y: 56, width: 912, height: 912)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 204, yRadius: 204)
let graphite = NSGradient(colors: [
    NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.096, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
    NSColor(calibratedRed: 0.25, green: 0.26, blue: 0.28, alpha: 1)
])!
graphite.draw(in: body, angle: 90)

NSGraphicsContext.current?.saveGraphicsState()
body.addClip()
let sheen = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0),
    NSColor.white.withAlphaComponent(0.16)
])!
sheen.draw(in: NSRect(x: 56, y: 620, width: 912, height: 348), angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

NSColor.white.withAlphaComponent(0.16).setStroke()
let hairline = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 10, dy: 10), xRadius: 196, yRadius: 196)
hairline.lineWidth = 3
hairline.stroke()

// 画面框偏左上，给右下徽标留出不重叠的位置。线宽按 32px 仍能看出是一格视频。
let frameRect = NSRect(x: 168, y: 356, width: 560, height: 404)
let frame = NSBezierPath(roundedRect: frameRect, xRadius: 72, yRadius: 72)
frame.lineWidth = 62
frame.lineJoinStyle = .round
NSColor.white.setStroke()
frame.stroke()

// 三角形重心放在画面中部略偏右，底边停在徽标上沿之上。
let play = NSBezierPath()
play.move(to: NSPoint(x: 392, y: 678))
play.line(to: NSPoint(x: 392, y: 458))
play.line(to: NSPoint(x: 592, y: 568))
play.close()
NSColor.white.setFill()
play.fill()

// 右下圆徽标完全落在圆角底内，只压住画面框的一角，不压播放三角。
let badgeRect = NSRect(x: 668, y: 176, width: 208, height: 208)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowBlurRadius = 16
shadow.set()
let badge = NSBezierPath(ovalIn: badgeRect)
let badgeFill = NSGradient(colors: [
    NSColor(calibratedWhite: 0.94, alpha: 1),
    NSColor(calibratedWhite: 1, alpha: 1)
])!
badgeFill.draw(in: badge, angle: 90)
NSGraphicsContext.current?.restoreGraphicsState()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 748, y: 340))
arrow.line(to: NSPoint(x: 800, y: 340))
arrow.line(to: NSPoint(x: 800, y: 268))
arrow.line(to: NSPoint(x: 842, y: 268))
arrow.line(to: NSPoint(x: 774, y: 200))
arrow.line(to: NSPoint(x: 706, y: 268))
arrow.line(to: NSPoint(x: 748, y: 268))
arrow.close()
NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png failed\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    fputs("write failed: \(error)\n", stderr)
    exit(1)
}
