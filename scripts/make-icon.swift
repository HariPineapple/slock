// Renders the Slock app icon (a red "recording" dot on a dark rounded square) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: ~10% inset, continuous-ish corner radius.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))!.draw(in: bg, angle: -90)

    let c = NSPoint(x: s / 2, y: s / 2)
    // Faint "lens" rings.
    for (r, a) in [(0.30, 0.10), (0.22, 0.16)] {
        let rr = rect.width * CGFloat(r)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        ring.lineWidth = max(1, s * 0.012)
        NSColor(white: 1, alpha: CGFloat(a)).setStroke()
        ring.stroke()
    }
    // Recording dot.
    let dr = rect.width * 0.13
    let dot = NSBezierPath(ovalIn: NSRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2))
    NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1),
               ending: NSColor(srgbRed: 0.88, green: 0.2, blue: 0.24, alpha: 1))!.draw(in: dot, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
