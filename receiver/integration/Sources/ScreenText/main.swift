import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Reads one emulator screenshot.
///   ScreenText <png>          prints recognized text, one observation per line, top to bottom
///   ScreenText --grid <png>   prints 48x20 luma samples (8x8 block means) of the band between the
///                             top labels and the diagnostics overlay (15%...47% of the height)
/// The receiver's diagnostics overlay cannot be read through UIAutomator while video plays (the UI
/// never becomes idle), so the integration check reads the pixels instead.
let arguments = CommandLine.arguments
let grid = arguments.count == 3 && arguments[1] == "--grid"
guard arguments.count == (grid ? 3 : 2), let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments.last!) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("usage: ScreenText [--grid] <png>\n".utf8)); exit(2)
}
if grid {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
    }
    guard drawn else { exit(1) }
    var values: [String] = []
    for gy in 0..<20 {
        let cy = Int(Double(height) * (0.15 + 0.32 * Double(gy) / 19))
        for gx in 0..<48 {
            let cx = Int(Double(width) * (0.04 + 0.92 * Double(gx) / 47))
            var sum = 0
            for dy in -4..<4 { for dx in -4..<4 {
                let i = ((cy + dy) * width + (cx + dx)) * 4
                sum += (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
            } }
            values.append(String(sum / 64))
        }
    }
    print("\(width)x\(height) " + values.joined(separator: " "))
    exit(0)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch {
    FileHandle.standardError.write(Data("OCR failed: \(error.localizedDescription)\n".utf8)); exit(1)
}
let lines = (request.results ?? []).compactMap { observation -> (CGRect, String)? in
    guard let text = observation.topCandidates(1).first?.string else { return nil }
    return (observation.boundingBox, text)
}.sorted { abs($0.0.midY - $1.0.midY) > 0.006 ? $0.0.midY > $1.0.midY : $0.0.minX < $1.0.minX }
for (box, text) in lines { print(String(format: "%.3f %.3f\t", box.minX, 1 - box.maxY) + text) }
