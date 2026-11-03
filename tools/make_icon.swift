// 1024px 앱 아이콘 PNG를 그린다. 사용: swift tools/make_icon.swift <출력.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha).cgColor
}

// 블루 버블: 메뉴바의 말풍선과 원형 구멍을 앱 아이콘에도 이어 쓴다.
let tile = CGPath(
    roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
    cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x263144, 0.16))
ctx.addPath(tile)
ctx.setFillColor(color(0x41649D))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let background = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x7195D5), color(0x41649D)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    background, start: CGPoint(x: 400, y: 924), end: CGPoint(x: 640, y: 100),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

let body = CGPath(
    roundedRect: CGRect(x: 215, y: 365, width: 594, height: 430),
    cornerWidth: 154, cornerHeight: 154, transform: nil)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 292, y: 438))
tail.addLine(to: CGPoint(x: 277, y: 274))
tail.addQuadCurve(to: CGPoint(x: 302, y: 263), control: CGPoint(x: 275, y: 250))
tail.addLine(to: CGPoint(x: 474, y: 387))
tail.closeSubpath()

// 별도 레이어에서 원을 뚫어 배경 그라데이션이 그대로 보이게 한다.
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
ctx.addPath(body)
ctx.fillPath()
ctx.addPath(tail)
ctx.fillPath()
ctx.setBlendMode(.destinationOut)
ctx.fillEllipse(in: CGRect(x: 405, y: 473, width: 214, height: 214))
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
