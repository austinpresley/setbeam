import AVFoundation

public enum CaptureDiscovery {
    /// Keep the ordering identical to the bundled FFmpeg 9 AVFoundation adapter.
    /// Resolve persistent identities again on every attempt; never persist an input index.
    public static func devices() -> [CaptureHardware] {
        func discover(_ types: [AVCaptureDevice.DeviceType], _ media: AVMediaType) -> [AVCaptureDevice] {
            AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified).devices
        }
        let video = discover([.builtInWideAngleCamera, .deskViewCamera, .continuityCamera, .external], .video)
            + discover([.external], .muxed)
        let audio = discover([.microphone], .audio)
        return video.enumerated().map { index, device in
            CaptureHardware(id: device.uniqueID, name: device.localizedName, index: index,
                            builtIn: device.deviceType == .builtInWideAngleCamera)
        } + audio.enumerated().map { index, device in
            CaptureHardware(id: device.uniqueID, name: device.localizedName, index: index, audio: true)
        }
    }
}

/// A capture format and cadence that the bundled AVFoundation input can open exactly.
public struct CaptureMode: Equatable, Sendable {
    public let width: Int32
    public let height: Int32
    public let frameRate: Double

    public var arguments: [String] { ["-video_size", "\(width)x\(height)", "-framerate", String(format: "%.6f", frameRate)] }

    /// Keeps the device's active size at the highest cadence it offers. FFmpeg activates the
    /// last listed format of the requested size with a range whose maximum equals the requested
    /// rate, so the rate comes from that same format.
    static func select(active: (width: Int32, height: Int32), formats: [(width: Int32, height: Int32, maxRates: [Double])]) -> CaptureMode? {
        guard active.width > 0, active.height > 0,
              let format = formats.last(where: { $0.width == active.width && $0.height == active.height }),
              let rate = format.maxRates.filter({ $0.isFinite && $0 > 0 }).max() else { return nil }
        return CaptureMode(width: active.width, height: active.height, frameRate: rate)
    }
}

extension CaptureDiscovery {
    public static func mode(forVideoID id: String) -> CaptureMode? {
        guard let device = AVCaptureDevice(uniqueID: id) else { return nil }
        let active = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let formats = device.formats.map { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (width: size.width, height: size.height, maxRates: format.videoSupportedFrameRateRanges.map(\.maxFrameRate))
        }
        return CaptureMode.select(active: (active.width, active.height), formats: formats)
    }
}
