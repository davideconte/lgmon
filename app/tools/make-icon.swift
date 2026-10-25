// Draws the app icon (dark squircle, white sun) and writes an .iconset folder.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with margins
    let body = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: path, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke()
    path.lineWidth = max(1, s * 0.004)
    path.stroke()
    // sun
    let c = NSPoint(x: s / 2, y: s / 2)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - s * 0.12, y: c.y - s * 0.12, width: s * 0.24, height: s * 0.24)).fill()
    NSColor.white.setStroke()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4
        let r1 = s * 0.175, r2 = s * 0.255
        let ray = NSBezierPath()
        ray.move(to: NSPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        ray.line(to: NSPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        ray.lineWidth = s * 0.045
        ray.lineCapStyle = .round
        ray.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
