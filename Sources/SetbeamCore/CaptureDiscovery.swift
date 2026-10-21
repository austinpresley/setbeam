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
