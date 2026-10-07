// 画图标：近黑底 + 青到蓝渐变的扫帚（Material 那类"一笔画"的粗线图标）。
// 用法：makeicon <输出.iconset 目录>
// 纯 CoreGraphics 画，不引外部素材，不含任何个人信息。

import Foundation
import AppKit
import CoreGraphics

let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// macOS 图标那种圆角方块：四条直边 + 连续圆角（G2）。
/// 别用超椭圆参数式 |x|^n+|y|^n=1 —— 它会把边鼓出来、把角切掉，看着"胖一圈"。
func roundedSquare(rect: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let path = CGMutablePath()
    let r = min(radius, min(rect.width, rect.height) / 2)
    let k = r * (1 + smoothing) * 0.45
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

    path.move(to: CGPoint(x: minX + r, y: maxY))
    path.addLine(to: CGPoint(x: maxX - r, y: maxY))
    path.addCurve(to: CGPoint(x: maxX, y: maxY - r),
                  control1: CGPoint(x: maxX - r + k, y: maxY),
                  control2: CGPoint(x: maxX, y: maxY - r + k))
    path.addLine(to: CGPoint(x: maxX, y: minY + r))
    path.addCurve(to: CGPoint(x: maxX - r, y: minY),
                  control1: CGPoint(x: maxX, y: minY + r - k),
                  control2: CGPoint(x: maxX - r + k, y: minY))
    path.addLine(to: CGPoint(x: minX + r, y: minY))
    path.addCurve(to: CGPoint(x: minX, y: minY + r),
                  control1: CGPoint(x: minX + r - k, y: minY),
                  control2: CGPoint(x: minX, y: minY + r - k))
    path.addLine(to: CGPoint(x: minX, y: maxY - r))
    path.addCurve(to: CGPoint(x: minX + r, y: maxY),
                  control1: CGPoint(x: minX, y: maxY - r + k),
                  control2: CGPoint(x: minX + r - k, y: maxY))
    path.closeSubpath()
    return path
}

/// 闪亮符号：四角星，竖直比水平长一点（Apple 那个 sparkle 的形状）。
/// 尖在上下左右，相邻尖之间用向内凹的曲线连起来。一个图标里就这一种形状，最省事也最耐看。
func sparkle(center: CGPoint, width: CGFloat, height: CGFloat, pinch: CGFloat = 0.26) -> CGPath {
    let path = CGMutablePath()
    let up = CGPoint(x: center.x, y: center.y + height)
    let right = CGPoint(x: center.x + width, y: center.y)
    let down = CGPoint(x: center.x, y: center.y - height)
    let left = CGPoint(x: center.x - width, y: center.y)
    path.move(to: up)
    path.addQuadCurve(to: right, control: CGPoint(x: center.x + width * pinch, y: center.y + height * pinch))
    path.addQuadCurve(to: down, control: CGPoint(x: center.x + width * pinch, y: center.y - height * pinch))
    path.addQuadCurve(to: left, control: CGPoint(x: center.x - width * pinch, y: center.y - height * pinch))
    path.addQuadCurve(to: up, control: CGPoint(x: center.x - width * pinch, y: center.y + height * pinch))
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat) -> CGImage? {
    guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let side = size * 0.86
    let plate = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
    let body = roundedSquare(rect: plate, radius: side * 0.2237)

    // 底：近黑，带一点冷色；外面一圈细边
    context.saveGState()
    context.addPath(body)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1),
                                          CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY),
                                   options: [])
    }
    context.restoreGState()

    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.13))
    context.setLineWidth(max(1, size * 0.006))
    context.addPath(body)
    context.strokePath()

    // 图标背后的青光
    let center = CGPoint(x: plate.midX, y: plate.midY)
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 0.28, green: 0.75, blue: 1, alpha: 0.26),
                                      CGColor(red: 0.28, green: 0.75, blue: 1, alpha: 0)] as CFArray,
                             locations: [0, 1]) {
        context.saveGState()
        context.addPath(body)
        context.clip()
        context.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: side * 0.62, options: [])
        context.restoreGState()
    }

    // 一大一小两颗星，青到蓝的渐变
    let big = sparkle(center: CGPoint(x: plate.midX + side * 0.05, y: plate.midY + side * 0.06),
                      width: side * 0.19, height: side * 0.28)
    let small = sparkle(center: CGPoint(x: plate.midX - side * 0.19, y: plate.midY - side * 0.20),
                        width: side * 0.07, height: side * 0.105)
    context.saveGState()
    context.addPath(big)
    context.addPath(small)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 0.45, green: 0.93, blue: 1.00, alpha: 1),
                                          CGColor(red: 0.15, green: 0.42, blue: 1.00, alpha: 1)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX + side * 0.25, y: plate.maxY - side * 0.15),
                                   end: CGPoint(x: plate.maxX - side * 0.15, y: plate.minY + side * 0.25),
                                   options: [])
    }
    context.restoreGState()

    return context.makeImage()
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("用法：makeicon <输出.iconset 目录>\n".data(using: .utf8)!)
    exit(2)
}
let directory = arguments[1]
try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

for size in sizes {
    guard let image = drawIcon(size: CGFloat(size)) else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let name = size <= 512 ? "icon_\(size)x\(size).png" : "icon_512x512@2x.png"
    try? data.write(to: URL(fileURLWithPath: directory + "/" + name))
    if size <= 512, size >= 32 {
        try? data.write(to: URL(fileURLWithPath: directory + "/icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
print("图标已写入 \(directory)")
