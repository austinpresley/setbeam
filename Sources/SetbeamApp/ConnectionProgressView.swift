import SwiftUI
import SetbeamCore

struct ConnectionProgressView: View {
    let stage: ConnectionStage
    let kind: InputKind
    var title: String?
    var compact = false

    private var steps: [ConnectionStage] { ConnectionStage.steps(for: kind) }
    private var index: Int { steps.firstIndex(of: stage) ?? 0 }

    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            if !compact { ProgressView().controlSize(.small).environment(\.colorScheme, .light).colorInvert() }
            VStack(spacing: compact ? 4 : 6) {
                Text(title ?? stage.title).font(.system(size: compact ? 12 : 14, weight: .medium))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("Step \(index + 1) of \(steps.count)")
                    .font(.system(size: compact ? 10 : 11)).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { position, _ in
                    Capsule().fill(.white.opacity(position == index ? 0.9 : position < index ? 0.45 : 0.14))
                        .frame(width: compact ? 20 : 24, height: 3)
                }
            }.accessibilityHidden(true)
        }
        .foregroundStyle(.white.opacity(0.9)).padding(compact ? 12 : 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title ?? stage.title). Step \(index + 1) of \(steps.count).")
    }
}
