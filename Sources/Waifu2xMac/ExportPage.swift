import SwiftUI
import UpscaleCore

struct ExportPage: View {
    @Bindable var workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summary
                settings
                files
            }.padding(.horizontal, 32).padding(.vertical, 20)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softTopScrollEdge()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                EngineSymbolTile(symbol: workspace.selectedEngineAppearance.symbol, size: 44)
                    .tinted(workspace.selectedEngineAppearance.tint, endTint: workspace.selectedEngineAppearance.endTint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(summaryTitle).font(.title2.weight(.semibold))
                    Text("\(workspace.batchEngineName) · \(workspace.options.sizeLabel) · \(workspace.destinationLabel)")
                        .foregroundStyle(.secondary)
                    if let job = workspace.selected {
                        HStack(spacing: 8) {
                            Text("Saves as").font(.caption).foregroundStyle(.secondary)
                            Text(workspace.options.export.outputName(for: job.source, kind: job.kind))
                                .font(.callout.monospaced()).padding(.vertical, 4).padding(.horizontal, 8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if workspace.isExporting {
                ProgressView(value: workspace.batchProgress).tint(Color(nsColor: .controlAccentColor))
                    .accessibilityLabel("Export progress")
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Save To").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Save To", selection: $workspace.besideOriginals) {
                            Text("Beside Originals").tag(true)
                            Text("Folder…").tag(false)
                        }.pickerStyle(.menu).labelsHidden().fixedSize()
                        if !workspace.besideOriginals {
                            HStack {
                                Label(workspace.folder?.lastPathComponent ?? "Select a destination", systemImage: "folder")
                                    .lineLimit(1).foregroundStyle(.secondary).help(workspace.folder?.path ?? "")
                                Button("Choose…", action: workspace.chooseFolder).fixedSize()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                GridRow(alignment: .firstTextBaseline) {
                    Text("Filename Suffix").foregroundStyle(.secondary)
                    TextField("Filename Suffix", text: $workspace.options.export.filenameSuffix).labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                }
                if workspace.jobs.contains(where: { $0.kind == .image }) {
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Format").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Picker("Format", selection: $workspace.options.export.imageFormat) {
                                ForEach(ImageFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                            if workspace.options.export.imageFormat == .jpeg {
                                HStack {
                                    Slider(value: $workspace.options.export.jpegQuality, in: 0.1...1, step: 0.01) {
                                        Text("JPEG Quality")
                                    }
                                    Text(workspace.options.export.jpegQuality.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption.monospacedDigit())
                                }.frame(width: 220)
                                Text("JPEG flattens transparent areas onto white.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("PNG preserves transparency and uses lossless compression.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if workspace.hasGIF {
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("GIF Speed").foregroundStyle(.secondary)
                        Picker("GIF Speed", selection: $workspace.options.export.gifSpeed) {
                            ForEach(GIFSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Loop Forever").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Loop Forever", isOn: $workspace.options.export.loopGIF).labelsHidden()
                            Text("With looping off here, exports keep the source loop count.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if workspace.hasVideo {
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Codec").foregroundStyle(.secondary)
                        Picker("Codec", selection: $workspace.options.export.videoCodec) {
                            ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Quality").foregroundStyle(.secondary)
                        Picker("Quality", selection: $workspace.options.export.videoQuality) {
                            ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    Divider()
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Keep Audio").foregroundStyle(.secondary)
                        Toggle("Keep Audio", isOn: $workspace.options.export.keepAudio).labelsHidden()
                    }
                }
            }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .disabled(workspace.isExporting)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files").font(.headline).padding(16)
            ForEach(workspace.jobs) { job in
                if job.id != workspace.jobs.first?.id { Divider().padding(.horizontal, 16) }
                HStack(spacing: 12) {
                    JobThumbnail(job: job, size: CGSize(width: 36, height: 36))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.source.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        JobStatusLine(workspace: workspace, job: job, showsMediaKind: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    JobStateIndicator(job: job)
                }.padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .contextMenu { JobActions(workspace: workspace, job: job) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var summaryTitle: String {
        if workspace.isExporting { return workspace.progressLabel }
        let count = workspace.jobs.count
        if workspace.hasRun {
            let failed = workspace.jobs.filter { if case .failed = $0.state { true } else { false } }.count
            if failed > 0 { return "\(workspace.completed) of \(count) exported · \(failed) failed" }
            if workspace.completed == count { return "\(count) \(count == 1 ? "file" : "files") exported" }
        }
        return "Ready to export \(count) \(count == 1 ? "file" : "files")"
    }
}
