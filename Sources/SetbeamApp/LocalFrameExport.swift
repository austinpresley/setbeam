import CoreImage
import Foundation
import ImageIO
import SetbeamCore

enum LocalFrameExport {
    static func save(_ picture: PreviewPicture, to destination: URL) throws {
        let original = CIImage(cvPixelBuffer: picture.pixelBuffer)
        let width = original.extent.width, height = original.extent.height
        let pixelAspect = (picture.size.width / picture.size.height) / (width / height)
        guard pixelAspect.isFinite, pixelAspect > 0 else { throw SetbeamError.runtime("The picture has an invalid aspect ratio.") }

        // Correct anamorphic pixels without reducing the smaller axis unless the
        // resulting image would exceed the decoder's raster limit.
        let squareWidth = width * max(1, pixelAspect)
        let squareHeight = height / min(1, pixelAspect)
        let limit = min(1, 8192 / max(squareWidth, squareHeight))
        let outputWidth = max(1, (squareWidth * limit).rounded())
        let outputHeight = max(1, (squareHeight * limit).rounded())
        let image = original.transformed(by: CGAffineTransform(scaleX: outputWidth / width, y: outputHeight / height))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: 0.95]) else {
            throw SetbeamError.runtime("The local picture could not be encoded.")
        }
        try jpeg.write(to: destination, options: .atomic)
    }
}
