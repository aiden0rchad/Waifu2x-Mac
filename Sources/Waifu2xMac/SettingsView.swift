import SwiftUI
import UpscaleCore

struct SettingsView: View {
    @Bindable var workspace: Workspace
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section {
                    Toggle("Reveal Completed Files in Finder", isOn: $workspace.revealWhenDone)
                    Toggle("Keep This Mac Awake During Export", isOn: $workspace.keepAwake)
                    Text("Ends when the export finishes or stops.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Recent Exports") {
                    LabeledContent {
                        Button("Clear Recent Exports", action: workspace.clearRecent).disabled(workspace.recent.isEmpty)
                    } label: {
                        Text(workspace.recent.isEmpty ? "None" : "\(workspace.recent.count) \(workspace.recent.count == 1 ? "file" : "files")")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("This Mac") {
                    LabeledContent("Apple ML Upscaling", value: Preset.available.contains(.enhance) ? "Available" : "Not Available")
                    LabeledContent("Apple Frame Interpolation", value: UpscaleOptions.canInterpolateVideo ? "Available" : "Not Available")
                }
            }
            .scrollDisabled(true)
            .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            Form {
                ForEach(OptionalEngine.all) { engine in
                    Section(engine.name) {
                        OptionalEngineControls(workspace: workspace, engine: engine)
                    }
                }
            }
            .tabItem { Label("AI Engines", systemImage: "cpu") }.tag(1)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: selectedTab == 0 ? 330 : enginesHeight)
    }

    private var enginesHeight: CGFloat {
        workspace.engineLibrary.states.values.contains { $0.downloading || $0.message != nil } ? 320 : 250
    }
}
