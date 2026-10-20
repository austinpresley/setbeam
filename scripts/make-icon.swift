import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let folder = root.appendingPathComponent("build/Setbeam.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
        NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.57, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.11, green: 0.22, blue: 0.78, alpha: 1))!.draw(in: tile, angle: -80)
        let screen = NSBezierPath(roundedRect: NSRect(x: 224, y: 270, width: 526, height: 370), xRadius: 54, yRadius: 54)
        NSColor.white.withAlphaComponent(0.94).setStroke(); screen.lineWidth = 37; screen.stroke()
        let floating = NSBezierPath(roundedRect: NSRect(x: 505, y: 483, width: 300, height: 215), xRadius: 39, yRadius: 39)
        NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.94, alpha: 1).setFill(); floating.fill()
        NSColor.white.setStroke(); floating.lineWidth = 35; floating.stroke()
        let beam = NSBezierPath(); beam.move(to: NSPoint(x: 567, y: 751)); beam.line(to: NSPoint(x: 611, y: 795)); beam.lineCapStyle = .round; beam.lineWidth = 31; beam.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: 273, y: 530, width: 34, height: 34)); NSColor.white.setFill(); dot.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
