import AppKit

/// 녹음 중 메뉴바에 띄울 그림: [마이크 막대] [스피커 막대] 경과 시간
enum StatusIcon {
    private static let height: CGFloat = 18
    private static let barSize = CGSize(width: 3, height: 13)
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

    static func recording(time: String, microphone: Float?, system: Float) -> NSImage {
        var parts: [(NSImage, Float)] = []
        if let microphone, let mic = symbol("mic.fill") { parts.append((mic, microphone)) }
        if let speaker = symbol("speaker.wave.2.fill") { parts.append((speaker, system)) }

        let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textSize = text.size()
        let partsWidth = parts.reduce(0) { $0 + $1.0.size.width + 2 + barSize.width + 6 }
        let size = NSSize(width: ceil(partsWidth + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (glyph, level) in parts {
                glyph.draw(in: NSRect(
                    x: x, y: (height - glyph.size.height) / 2,
                    width: glyph.size.width, height: glyph.size.height))
                x += glyph.size.width + 2
                drawBar(at: x, level: level)
                x += barSize.width + 6
            }
            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 대기 중 메뉴바 그림: 말풍선 안에 녹음 점을 뚫은 템플릿 이미지 (1x, 2x 비트맵)
    static let idle: NSImage = {
        let image = NSImage(size: NSSize(width: height, height: height))
        for scale: CGFloat in [1, 2] {
            let pixels = Int(height * scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep)
            else { continue }
            rep.size = image.size
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            drawBubble(in: ctx)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }()

    /// 18pt 격자에 말풍선(몸통 + 꼬리)을 채우고 가운데를 동그랗게 비운다.
    private static func drawBubble(in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: 1.5, y: 4, width: 15, height: 11),
            cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.move(to: CGPoint(x: 3.5, y: 5.5))
        ctx.addLine(to: CGPoint(x: 3.5, y: 1))
        ctx.addLine(to: CGPoint(x: 8.5, y: 4.5))
        ctx.closePath()
        ctx.fillPath()
        ctx.setBlendMode(.destinationOut)
        ctx.fillEllipse(in: CGRect(x: 6, y: 6.5, width: 6, height: 6))
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
    }

    private static func drawBar(at x: CGFloat, level: Float) {
        let track = NSRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        let filled = max(CGFloat(level) * track.height, level > 0.02 ? 2 : 0)
        guard filled > 0 else { return }
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: filled),
            xRadius: 1.5, yRadius: 1.5
        ).fill()
    }
}
