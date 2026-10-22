// Rebuild with: xcrun swift -module-cache-path build/notebook-macos/swift-cache \
//   tools/notebook-macos/Assets/generate-icon.swift tools/notebook-macos/Assets
// Vector artwork in the Sputnik Night Sky / Foxglove / Lily White palette.
// The satellite geometry follows site/public/assets/sputnik-mark.svg.
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func stroke(_ points: [NSPoint], color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

func drawIcon() {
    let night = color(0x2a2a35)
    let rose = color(0xb98391)
    let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                            xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    night.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x41414f), ending: color(0x22222c))!
        .draw(in: tile, angle: -90)
    color(0xffffff, alpha: 0.12).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    let bookTransform = NSAffineTransform()
    bookTransform.translateX(by: 512, yBy: 512)
    bookTransform.rotate(byDegrees: -7)
    bookTransform.translateX(by: -512, yBy: -512)
    bookTransform.concat()

    let cover = NSBezierPath(roundedRect: NSRect(x: 264, y: 192, width: 496, height: 640),
                             xRadius: 46, yRadius: 46)
    NSGraphicsContext.saveGraphicsState()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.36)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 4, height: -16)
    shadow.set()
    rose.setFill()
    cover.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xc997a4), ending: rose)!.draw(in: cover, angle: -90)

    let page = NSBezierPath(roundedRect: NSRect(x: 310, y: 206, width: 438, height: 612),
                            xRadius: 34, yRadius: 34)
    NSGradient(starting: color(0xf5f3ec), ending: color(0xe2e2da))!
        .draw(in: page, angle: -90)
    stroke([NSPoint(x: 321, y: 248), NSPoint(x: 321, y: 776)],
           color: color(0x2a2a35, alpha: 0.10), width: 3)
    stroke([NSPoint(x: 380, y: 316), NSPoint(x: 658, y: 316)],
           color: color(0x2a2a35, alpha: 0.30), width: 12)
    stroke([NSPoint(x: 380, y: 271), NSPoint(x: 580, y: 271)],
           color: color(0x2a2a35, alpha: 0.18), width: 12)

    let bookmark = NSBezierPath()
    bookmark.move(to: NSPoint(x: 652, y: 818))
    bookmark.line(to: NSPoint(x: 652, y: 747))
    bookmark.line(to: NSPoint(x: 674, y: 763))
    bookmark.line(to: NSPoint(x: 696, y: 747))
    bookmark.line(to: NSPoint(x: 696, y: 818))
    bookmark.close()
    rose.setFill()
    bookmark.fill()

    // Preserve the brand mark's proportions, with heavier strokes for the Dock.
    NSGraphicsContext.saveGraphicsState()
    let markTransform = NSAffineTransform()
    markTransform.translateX(by: 332, yBy: 739)
    markTransform.scaleX(by: 8, yBy: -8)
    markTransform.concat()
    let orbit = NSBezierPath(ovalIn: NSRect(x: 0, y: 13, width: 50, height: 22))
    let orbitTransform = NSAffineTransform()
    orbitTransform.translateX(by: 25, yBy: 24)
    orbitTransform.rotate(byDegrees: -43)
    orbitTransform.translateX(by: -25, yBy: -24)
    orbit.transform(using: orbitTransform as AffineTransform)
    orbit.lineWidth = 1.7
    rose.setStroke()
    orbit.stroke()
    for line in [[NSPoint(x: 24, y: 18), NSPoint(x: 4, y: 33)],
                 [NSPoint(x: 29, y: 23), NSPoint(x: 8, y: 45)],
                 [NSPoint(x: 36, y: 25), NSPoint(x: 24, y: 44)],
                 [NSPoint(x: 24, y: 13), NSPoint(x: 7, y: 26)]] {
        stroke(line, color: rose, width: 1.8)
    }
    rose.setFill()
    NSBezierPath(ovalIn: NSRect(x: 22, y: 6, width: 20, height: 20)).fill()
    let meridian = NSBezierPath()
    meridian.move(to: NSPoint(x: 25, y: 9))
    meridian.curve(to: NSPoint(x: 40, y: 25),
                   controlPoint1: NSPoint(x: 25, y: 18),
                   controlPoint2: NSPoint(x: 32, y: 25))
    meridian.move(to: NSPoint(x: 24, y: 16))
    meridian.line(to: NSPoint(x: 40, y: 24))
    meridian.lineWidth = 1.2
    color(0xe2e2da).setStroke()
    meridian.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "tools/notebook-macos/Assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("sputnik-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(size: size * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try png(size: 1024).write(to: output.appendingPathComponent("AppIcon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Created AppIcon.png and AppIcon.icns in \(output.path)")
