import SwiftUI
import SetbeamCore

struct PictureSettingsView: View {
    @ObservedObject var model: SessionModel
    @State private var quality: AudienceQuality
    @State private var frameRate: VideoFrameRate
    @State private var screenRate: VideoFrameRate

    init(model: SessionModel) {
        self.model = model
        _quality = State(initialValue: model.audienceQuality)
        _frameRate = State(initialValue: model.audienceFrameRate)
        _screenRate = State(initialValue: model.screenFrameRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Picture settings").font(.title2.weight(.semibold))
            Form {
                Section("Viewers") {
                    Picker("Picture quality", selection: $quality) {
                        ForEach(AudienceQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Frame rate", selection: $frameRate) {
                        ForEach(VideoFrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Lower frame rates favor detail over motion. Image dimensions stay the same. Changes reconnect viewers; your local monitor continues.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.setup?.kind == .macScreen {
                    Section("This Mac's screen") {
                        Picker("Capture frame rate", selection: $screenRate) {
                            ForEach(VideoFrameRate.allCases, id: \.self) { rate in
                                Text(rate == .source ? "Match display" : rate.title).tag(rate)
                            }
                        }
                        Text("Sets the rate captured for both local monitoring and sharing. Viewer frame rate can be lower.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).frame(height: model.setup?.kind == .macScreen ? 340 : 210)
            HStack {
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    model.setVideoSettings(quality: quality, frameRate: frameRate, screenRate: screenRate)
                    model.sheet = nil
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(24).frame(width: 500)
    }
}
