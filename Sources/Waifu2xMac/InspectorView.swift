import SwiftUI
import UpscaleCore

struct InspectorView: View {
    @Bindable var workspace: Workspace
    @State private var showMore = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section { OutputHero(workspace: workspace) }
            Section("Engine") {
                HStack(alignment: .top, spacing: 10) {
                    EngineSymbolTile(symbol: workspace.selectedEngineAppearance.symbol, size: 32)
                        .tinted(workspace.selectedEngineAppearance.tint, endTint: workspace.selectedEngineAppearance.endTint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.selectedEngineName).font(.headline)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Text(workspace.selectedEngineTagline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") { workspace.page = .engine }.glassButton().controlSize(.small)
                }
            }
            if workspace.options.usesAI {
                Section("AI Restore") {
                    ReferenceImagesView(workspace: workspace)
                    LabeledContent("Strength · \(Int(workspace.options.restore.strength * 100))%") {
                        Slider(value: $workspace.options.restore.strength, in: 0...1)
                            .accessibilityLabel("AI Restore strength")
                    }
                    Toggle("Keep Original Colours", isOn: $workspace.options.restore.keepOriginalColours)
                    Toggle("Protect Text", isOn: $workspace.options.restore.protectStructure)
                        .help("Repairs text and thick lines that AI turns into outlines.")
                    if workspace.aiUnsupportedCount > 0 {
                        Label {
                            Text("Videos use \(workspace.videoEngineName).").foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                        }.font(.caption)
                    }
                    DisclosureGroup(isExpanded: $showMore) {
                        VStack(alignment: .leading, spacing: 10) {
                            RestoreAdvancedControls(options: $workspace.options)
                        }.padding(.top, 6)
                    } label: {
                        Button { showMore.toggle() } label: {
                            Text("More").frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(showMore ? "Expanded" : "Collapsed")
                    }
                }
            }
            if workspace.hasVideo || (workspace.hasGIF && !workspace.options.usesAI) {
                Section("Motion") {
                    MotionControls(options: $workspace.options, hasVideo: workspace.hasVideo, hasGIF: workspace.hasGIF)
                }
            }
            if !workspace.usesOnlyVideoModel || !workspace.options.usesTemporalVideo {
                Section {
                    DetailControls(options: $workspace.options)
                } header: { Text("Detail") }
            }
        }
        .formStyle(.grouped)
        .softTopScrollEdge()
        .animation(reduceMotion ? nil : .smooth, value: workspace.options.usesAI)
        .disabled(workspace.isExporting)
    }
}
