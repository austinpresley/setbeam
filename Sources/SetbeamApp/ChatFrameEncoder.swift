import AppKit
import CoreImage
import ImageIO

enum ChatFrameEncoder {
    /// A one-shot user action, called off the UI actor. Live preview paths stay unchanged.
    static func encode(_ picture: PreviewPicture) -> Data? {
        let original = CIImage(cvPixelBuffer: picture.pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        for maximum in [960.0, 640.0] {
            let scale = min(1, maximum / max(original.extent.width, original.extent.height))
            let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            for quality in [0.7, 0.45, 0.25, 0.1] {
                let option = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                if let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [option: quality]), data.count <= 131_072 { return data }
            }
        }
        return nil
    }
}
