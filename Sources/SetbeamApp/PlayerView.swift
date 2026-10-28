import SwiftUI
import AppKit
import SetbeamCore

struct PlayerView: View {
    @ObservedObject var player: NativePreview
    var placeholder = "Connecting to source"
    var physicalStep = false
    var connectionStage: ConnectionStage?
    var inputKind: InputKind = .sample
    var stageTitle: String?
    var lastPicture: String?
    var compactProgress = false
    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14)
            if let picture = player.picture {
                PictureView(picture: picture)
                    .accessibilityLabel(connectionStage == nil ? "Live feed preview" : "Last received picture")
            }
            if let connectionStage {
                if player.picture != nil { Color.black.opacity(0.72) }
                VStack(spacing: 0) {
                    ConnectionProgressView(stage: connectionStage, kind: inputKind, title: stageTitle, compact: compactProgress)
                    if let lastPicture {
                        Text(lastPicture).font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else if player.picture == nil {
                if physicalStep {
                    VStack(spacing: 12) { Image(systemName: "cable.connector").font(.largeTitle); Text(placeholder).font(.callout) }.foregroundStyle(.secondary).padding(20)
                } else { ProgressView(placeholder).controlSize(.small).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}
