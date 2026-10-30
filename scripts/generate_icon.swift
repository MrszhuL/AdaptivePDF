import AppKit

// Reproducible geometric artwork; no downloaded or generated external assets.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let size = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 194, yRadius: 194)
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.19, blue: 0.35, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.48, blue: 0.52, alpha: 1))!.draw(in: background, angle: -45)
    let paper = NSBezierPath(roundedRect: NSRect(x: 256, y: 190, width: 512, height: 644), xRadius: 40, yRadius: 40)
    NSColor(white: 0.98, alpha: 1).setFill(); paper.fill()
    NSGraphicsContext.saveGraphicsState()
    paper.addClip()
    NSColor(srgbRed: 0.14, green: 0.17, blue: 0.21, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 512, y: 190, width: 256, height: 644)).fill()
    for line in 0..<6 {
        let y = CGFloat(638 - line * 64)
        let width: CGFloat = line == 5 ? 98 : 146
        NSColor(srgbRed: 0.22, green: 0.32, blue: 0.40, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 306, y: y, width: width, height: 18), xRadius: 9, yRadius: 9).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 558, y: y, width: width, height: 18), xRadius: 9, yRadius: 9).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 1, green: 0.83, blue: 0.23, alpha: 0.80).setFill()
    NSBezierPath(roundedRect: NSRect(x: 294, y: 494, width: 436, height: 42), xRadius: 10, yRadius: 10).fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
