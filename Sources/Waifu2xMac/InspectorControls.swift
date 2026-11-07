import SwiftUI
import UpscaleCore

struct DetailControls: View {
    @Binding var options: UpscaleOptions

    var body: some View {
        LabeledContent("Noise Reduction") {
            Picker("Noise Reduction", selection: $options.noiseReduction) {
                ForEach(DetailLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().help("Transparent frames skip these filters.")
        }
        LabeledContent("Edge Detail") {
            Picker("Edge Detail", selection: $options.edgeDetail) {
                ForEach(DetailLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().help("Transparent frames skip these filters.")
        }
    }
}

struct DestinationControls: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Save To", selection: $workspace.besideOriginals) {
                Text("Beside Originals").tag(true)
                Text("Folder…").tag(false)
            }.pickerStyle(.menu)
            if !workspace.besideOriginals {
                HStack {
                    Label(workspace.folder?.lastPathComponent ?? "Select a destination", systemImage: "folder")
                        .lineLimit(1).foregroundStyle(.secondary).help(workspace.folder?.path ?? "")
                    Spacer()
                    Button("Choose…", action: workspace.chooseFolder)
                }
            }
        }
    }
}

struct ImageControls: View {
    @Binding var settings: ExportSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Format", selection: $settings.imageFormat) {
                ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if settings.imageFormat == .jpeg {
                HStack {
                    Slider(value: $settings.jpegQuality, in: 0.1...1, step: 0.01) { Text("JPEG Quality") }
                    Text(settings.jpegQuality.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                }
                Text("JPEG flattens transparent areas onto white.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("PNG preserves transparency and uses lossless compression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct GIFControls: View {
    @Binding var settings: ExportSettings

    var body: some View {
        Picker("GIF Speed", selection: $settings.gifSpeed) {
            ForEach(GIFSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Loop Forever", isOn: $settings.loopGIF)
        Text("With looping off here, exports keep the source loop count.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct VideoEngineControls: View {
    @Binding var options: UpscaleOptions

    var body: some View {
        LabeledContent("Video") {
            Picker("Video", selection: $options.videoEngine) {
                ForEach(VideoEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden()
        }
        Text(options.videoEngine.inputNote).font(.caption).foregroundStyle(.secondary)
    }
}

struct VideoControls: View {
    @Binding var options: UpscaleOptions

    var body: some View {
        Picker("Codec", selection: $options.export.videoCodec) {
            ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        Picker("Quality", selection: $options.export.videoQuality) {
            ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Toggle("Keep Audio", isOn: $options.export.keepAudio)
    }
}

struct MotionControls: View {
    @Binding var options: UpscaleOptions
    let hasVideo: Bool
    let hasGIF: Bool

    var body: some View {
        Picker("Smoother Motion", selection: $options.motionEngine) {
            Text(MotionEngine.off.rawValue).tag(MotionEngine.off)
            Text(MotionEngine.rife.rawValue).tag(MotionEngine.rife)
            if (hasVideo && UpscaleOptions.canInterpolateVideo) || options.motionEngine == .apple {
                Text(MotionEngine.apple.rawValue).tag(MotionEngine.apple)
                    .disabled(!hasVideo || !UpscaleOptions.canInterpolateVideo)
            }
        }
        .disabled(options.usesTemporalVideo && (!hasGIF || options.usesAI))
        .help("RIFE supports inputs up to 1,920 pixels per side and 2.07 MP; GIF frames must be opaque.")
        Text(note).font(.caption).foregroundStyle(.secondary)
    }

    private var note: String {
        if hasVideo && options.usesTemporalVideo {
            return hasGIF && !options.usesAI ? "RIFE applies only to opaque GIFs."
                : "Temporal video keeps the source cadence."
        }
        if options.motionEngine == .apple { return "Smooths video on supported Macs." }
        if options.usesAI { return "RIFE smooths video only." }
        return hasVideo ? "RIFE smooths video and opaque GIFs." : "RIFE inserts frames into opaque GIFs."
    }
}

struct SizeControls: View {
    @Binding var options: UpscaleOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassGroup {
                HStack(spacing: 6) {
                    ForEach(OutputSize.allCases.filter(\.isScale), id: \.self) { size in
                        scaleButton(size).frame(maxWidth: .infinity)
                    }
                    targets.frame(maxWidth: .infinity)
                }.controlSize(.regular)
            }.accessibilityElement(children: .contain).accessibilityLabel("Output Size")
            if options.size == .custom {
                HStack {
                    TextField("Width", value: $options.customWidth, format: .number.grouping(.never))
                        .accessibilityLabel("Custom width")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $options.customHeight, format: .number.grouping(.never))
                        .accessibilityLabel("Custom height")
                    Text("px").foregroundStyle(.secondary)
                }
            }
            if !options.size.isScale {
                Toggle("Keep Aspect Ratio", isOn: $options.fitInside)
                Text(options.fitInside ? "Fits inside the target size." : "Stretches to fill the target size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func scaleButton(_ size: OutputSize) -> some View {
        Button { options.size = size } label: {
            chipLabel(size.rawValue, selected: options.size == size)
        }.buttonStyle(.plain).accessibilityLabel(size.rawValue)
            .accessibilityAddTraits(options.size == size ? .isSelected : [])
    }

    private var targets: some View {
        Menu {
            Picker("Output Size", selection: $options.size) {
                ForEach(OutputSize.allCases.filter { !$0.isScale }, id: \.self) { size in
                    Text(size.rawValue).tag(size)
                }
            }.pickerStyle(.inline)
        } label: {
            chipLabel(options.size.isScale ? "More" : options.size.rawValue,
                      selected: !options.size.isScale, showsChevron: true)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Target Output Size")
            .accessibilityValue(options.size.isScale ? "More" : options.size.rawValue)
            .accessibilityAddTraits(options.size.isScale ? [] : .isSelected)
    }

    private func chipLabel(_ title: String, selected: Bool, showsChevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if showsChevron {
                Image(systemName: "chevron.down").font(.caption2.bold())
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 4).frame(maxWidth: .infinity).frame(height: 28)
        .background(selected ? Color.accentColor : Color.clear, in: Capsule())
        .glassSurface(Capsule(), interactive: true)
    }
}
