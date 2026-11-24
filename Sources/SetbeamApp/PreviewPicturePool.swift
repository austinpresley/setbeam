import AppKit
import CoreVideo

/// Confined to the playback picture queue. Every native monitor shares these IOSurfaces.
final class PreviewPicturePool {
    /// A pool reuses buffers but does not limit allocations unless every request supplies this
    /// threshold. Renderers can retain pixel buffers after the PreviewPicture wrapper is gone.
    /// Eight NV12 surfaces use about 96 MiB at 4K, regardless of how long a consumer is stalled.
    static let maximumBuffers = 8
    private let allocationLimits = [kCVPixelBufferPoolAllocationThresholdKey: maximumBuffers] as CFDictionary
    private let allocations: PreviewBufferAllocations
    private let allocationKey = "app.setbeam.preview-buffer-allocation" as CFString
    private var pool: CVPixelBufferPool?
    private var poolFormat = (width: 0, height: 0, format: OSType(0))

    init(allocations: PreviewBufferAllocations? = nil) {
        self.allocations = allocations ?? PreviewBufferAllocations(limit: Self.maximumBuffers)
    }

    func makePicture(_ frame: PreviewPacket) -> PreviewPicture? {
        let format = frame.flags & 1 != 0 ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if pool == nil || poolFormat != (frame.width, frame.height, format) {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferWidthKey: frame.width,
                                               kCVPixelBufferHeightKey: frame.height, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            pool = nil; CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolFormat = (frame.width, frame.height, format)
        }
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationLimits, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        // This lease follows the CVPixelBuffer into renderers, including after its pool has
        // been replaced by a new format. A per-pool threshold alone resets on every resize.
        if CVBufferCopyAttachment(pixelBuffer, allocationKey, nil) == nil {
            guard let lease = allocations.reserve() else { return nil }
            CVBufferSetAttachment(pixelBuffer, allocationKey, lease, .shouldNotPropagate)
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        frame.payload.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            for plane in 0..<2 {
                let rows = plane == 0 ? frame.height : frame.height / 2
                let start = plane == 0 ? 0 : frame.width * frame.height
                guard let destination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                if stride == frame.width { memcpy(destination, source.advanced(by: start), rows * frame.width); continue }
                for row in 0..<rows { memcpy(destination.advanced(by: row * stride), source.advanced(by: start + row * frame.width), frame.width) }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let matrix: CFString
        switch frame.matrix {
        case 1: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 7: matrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        case 9: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let aspect: [CFString: Int] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: frame.aspectNumerator,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: frame.aspectDenominator
        ]
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, aspect as CFDictionary, .shouldPropagate)

        let primaries: CFString?
        switch frame.colorPrimaries {
        case 1: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        case 5: primaries = kCVImageBufferColorPrimaries_EBU_3213
        case 6, 7: primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case 9: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        case 11: primaries = kCVImageBufferColorPrimaries_DCI_P3
        case 12: primaries = kCVImageBufferColorPrimaries_P3_D65
        default: primaries = nil
        }
        let transfer: CFString?
        switch frame.transferFunction {
        case 1, 6: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        case 7: transfer = kCVImageBufferTransferFunction_SMPTE_240M_1995
        case 8: transfer = kCVImageBufferTransferFunction_Linear
        case 13: transfer = kCVImageBufferTransferFunction_sRGB
        case 14, 15: transfer = kCVImageBufferTransferFunction_ITU_R_2020
        case 16: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: transfer = nil
        }
        // Reused surfaces must lose tags the next frame does not supply.
        for (key, value) in [(kCVImageBufferColorPrimariesKey, primaries), (kCVImageBufferTransferFunctionKey, transfer)] {
            if let value { CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate) }
            else { CVBufferRemoveAttachment(pixelBuffer, key) }
        }
        let size = NSSize(width: Double(frame.width) * Double(frame.aspectNumerator) / Double(frame.aspectDenominator), height: Double(frame.height))
        return PreviewPicture(pixelBuffer: pixelBuffer, size: size)
    }
}

/// Core Video can release an old format's last buffer on a renderer thread.
final class PreviewBufferAllocations {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    init(limit: Int) { self.limit = limit }
    fileprivate func reserve() -> PreviewBufferAllocation? {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return nil }
        count += 1
        return PreviewBufferAllocation(owner: self)
    }
    func release() { lock.lock(); count -= 1; lock.unlock() }
}

private final class PreviewBufferAllocation: NSObject {
    private let owner: PreviewBufferAllocations
    init(owner: PreviewBufferAllocations) { self.owner = owner }
    deinit { owner.release() }
}
