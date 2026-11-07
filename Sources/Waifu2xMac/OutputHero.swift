import SwiftUI
import UpscaleCore

struct OutputHero: View {
    @Bindable var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var input: Dimensions? {
        workspace.preview?.input ?? workspace.selected.flatMap { MediaMetadata.shared.sizes[$0.id] }
    }
    private var output: Dimensions? {
        input.flatMap { try? workspace.options.dimensions(for: $0, video: workspace.selected?.kind == .video) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(output?.label ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth, value: output?.label)
            if let input, let output {
                Text("from \(input.label) · \(megapixels(input)) MP → \(megapixels(output)) MP")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SizeControls(options: $workspace.options)
            if workspace.invalidCustomSize {
                Text("Enter a width and height.").font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: workspace.selection) {
            if let job = workspace.selected { await MediaMetadata.shared.load(job) }
        }
    }

    private func megapixels(_ size: Dimensions) -> String {
        (Double(size.width) * Double(size.height) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
    }
}
