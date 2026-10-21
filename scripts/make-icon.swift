import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("Assets/Setbeam.png")
guard let image = NSImage(contentsOf: artwork) else {
    fatalError("Could not load the approved Setbeam artwork at \(artwork.path)")
}

// The approved 1254 px proof has a 42 px white presentation margin.
// Fit its tile to the existing Mac icon inset, with transparent outer corners.
let source = NSRect(x: image.size.width * 42 / 1254, y: image.size.height * 42 / 1254,
                    width: image.size.width * 1170 / 1254, height: image.size.height * 1170 / 1254)
let folder = root.appendingPathComponent("build/Setbeam.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let factor = CGFloat(pixels) / 1024
        let tile = NSRect(x: 80 * factor, y: 80 * factor, width: 864 * factor, height: 864 * factor)
        NSBezierPath(roundedRect: tile, xRadius: 190 * factor, yRadius: 190 * factor).addClip()
        image.draw(in: tile, from: source, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
