import SwiftUI
import UpscaleCore

struct PresetsMenu: View {
    @Bindable var workspace: Workspace
    @State private var presetName = ""
    @State private var savePreset = false

    var body: some View {
        Menu {
            Button("Anime 2×") { workspace.options = UpscaleOptions(preset: .anime4k) }
            Button("Photo 2×") { workspace.options = UpscaleOptions(preset: .waifu2xPhoto) }
            Button("Illustration 2×") { workspace.options = UpscaleOptions(preset: .waifu2xArt) }
            Button("Quick Upscale") { workspace.options = UpscaleOptions(preset: .fast) }
            if workspace.hasVideo {
                Button("Restore Video 4×") {
                    workspace.options = UpscaleOptions(size: .quadruple, preset: .fast)
                    workspace.options.videoEngine = .nano
                    workspace.options.export.videoQuality = .high
                }
            }
            Section("Saved Presets") {
                ForEach(workspace.presets) { preset in
                    Button(preset.name) {
                        workspace.options = preset.options
                        if !Preset.available.contains(workspace.options.preset) { workspace.options.preset = .illustration }
                    }
                }
            }
            Button("Save Preset…") { presetName = ""; savePreset = true }
            Menu("Remove Preset") {
                ForEach(workspace.presets) { preset in
                    Button(preset.name, role: .destructive) { workspace.deletePreset(preset) }
                }
            }.disabled(workspace.presets.isEmpty)
            Divider()
            Menu("Restore Defaults") {
                Button("Engine") { restoreEngineDefaults() }
                Button("Output") {
                    workspace.besideOriginals = true
                    workspace.options.export.filenameSuffix = ExportSettings().filenameSuffix
                }
                Button("Video") {
                    workspace.options.motionEngine = .off
                    workspace.options.videoEngine = .spatial
                    workspace.options.export.videoCodec = ExportSettings().videoCodec
                    workspace.options.export.videoQuality = ExportSettings().videoQuality
                    workspace.options.export.keepAudio = ExportSettings().keepAudio
                }
                Button("GIF & Images") {
                    workspace.options.motionEngine = .off
                    workspace.options.export.imageFormat = ExportSettings().imageFormat
                    workspace.options.export.jpegQuality = ExportSettings().jpegQuality
                    workspace.options.export.gifSpeed = ExportSettings().gifSpeed
                    workspace.options.export.loopGIF = ExportSettings().loopGIF
                }
            }
        } label: { Label("Presets", systemImage: "ellipsis.circle") }
        .menuStyle(.borderlessButton).labelsHidden().fixedSize().accessibilityLabel("Presets")
        .alert("Save Preset", isPresented: $savePreset) {
            TextField("Preset Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { workspace.savePreset(presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func restoreEngineDefaults() {
        let defaults = UpscaleOptions()
        workspace.options.optionalEngineID = nil
        workspace.options.restore = defaults.restore
        workspace.options.preset = defaults.preset
        workspace.options.noiseReduction = defaults.noiseReduction
        workspace.options.edgeDetail = defaults.edgeDetail
        workspace.options.size = defaults.size
        workspace.options.customWidth = defaults.customWidth
        workspace.options.customHeight = defaults.customHeight
        workspace.options.fitInside = defaults.fitInside
    }
}
