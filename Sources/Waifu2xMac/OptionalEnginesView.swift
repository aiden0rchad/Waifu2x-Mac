import SwiftUI
import UpscaleCore

@MainActor @Observable
final class OptionalEngineLibrary {
    struct State {
        var installed = false
        var downloading = false
        var paused = false
        var bytes: Int64 = 0
        var removalBytes: Int64 = 0
        var progress: EngineDownloadProgress?
        var message: String?
    }
    var states: [String: State] = [:]
    var checking = true
    @ObservationIgnored private let installer = EngineInstaller()
    @ObservationIgnored private var task: Task<Void, Never>?

    init() { Task { await refresh() } }
    subscript(_ engine: OptionalEngine) -> State { states[engine.id] ?? State() }

    private func refresh() async {
        for engine in OptionalEngine.all {
            var state = self[engine]
            state.installed = await installer.installed(engine)
            state.bytes = await installer.diskBytes(engine)
            state.removalBytes = await installer.removalBytes(engine)
            let partial = await installer.hasPartialInstall(engine)
            state.paused = !state.installed && partial
            states[engine.id] = state
        }
        checking = false
    }

    func download(_ engine: OptionalEngine) {
        guard task == nil else { return }
        states[engine.id, default: State()].downloading = true
        states[engine.id]?.message = nil
        task = Task {
            do {
                try await installer.install(engine) { [weak self] progress in
                    Task { @MainActor in self?.states[engine.id]?.progress = progress }
                }
            } catch {
                if !Task.isCancelled { states[engine.id]?.message = error.localizedDescription }
            }
            states[engine.id]?.downloading = false
            await Task { await self.refresh() }.value
            task = nil
        }
    }

    func pause() { task?.cancel() }

    func cancel(_ engine: OptionalEngine) {
        let running = task
        running?.cancel()
        Task {
            await running?.value
            remove(engine)
        }
    }

    func remove(_ engine: OptionalEngine) {
        guard task == nil else { return }
        task = Task {
            do {
                let freed = try await installer.remove(engine)
                states[engine.id] = State(message: "Freed \(Self.size(freed))")
            } catch { states[engine.id]?.message = error.localizedDescription }
            await refresh()
            task = nil
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct OptionalEngineControls: View {
    @Bindable var workspace: Workspace
    let engine: OptionalEngine
    var compact = false
    @State private var confirmRemove = false
    private var library: OptionalEngineLibrary { workspace.engineLibrary }
    private var state: OptionalEngineLibrary.State { library[engine] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                Text(state.installed ? "Installed · \(OptionalEngineLibrary.size(state.bytes)) · \(engine.requiredRAMGB) GB RAM" : "AI runtime 1.3 GB + model 4.6 GB · \(engine.requiredRAMGB) GB RAM")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent(state.installed ? "Installed" : "Download",
                               value: "\(OptionalEngineLibrary.size(state.installed ? state.bytes : engine.downloadBytes + OptionalEngine.runtimeBytes)) · needs \(engine.requiredRAMGB) GB RAM")
            }
            HStack {
                Spacer(minLength: 0)
                if state.downloading {
                    Button("Pause") { library.pause() }
                    Button("Cancel", role: .cancel) { library.cancel(engine) }
                } else if state.installed || state.paused {
                    if state.paused { Button("Resume") { library.download(engine) }.buttonStyle(.borderedProminent) }
                    if !compact {
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                            .disabled(workspace.isExporting || workspace.isGeneratingAI)
                    }
                    if state.paused { Button("Cancel", role: .cancel) { library.cancel(engine) } }
                } else {
                    Button("Download") { library.download(engine) }.buttonStyle(.borderedProminent)
                        .disabled(library.checking)
                }
            }
            if state.downloading {
                if let progress = state.progress {
                    ProgressView(value: progress.fraction)
                        .accessibilityLabel("Engine download")
                    HStack {
                        Text(progress.phase)
                        Spacer()
                        if progress.bytesPerSecond > 0 {
                            Text(OptionalEngineLibrary.size(Int64(progress.bytesPerSecond)) + "/s")
                            if let seconds = progress.secondsLeft { Text("\(Int(seconds / 60)) min left") }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                } else { ProgressView("Preparing download…").controlSize(.small) }
            }
            if let message = state.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Link(engine.licence, destination: engine.licenceURL).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .contextMenu {
            if !compact && (state.installed || state.paused) {
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(workspace.isExporting || workspace.isGeneratingAI)
            }
        }
        .alert("Remove \(engine.name)?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if workspace.options.optionalEngineID == engine.id { workspace.options.optionalEngineID = nil }
                library.remove(engine)
            }.disabled(workspace.isExporting || workspace.isGeneratingAI)
        } message: {
            Text("Free \(OptionalEngineLibrary.size(state.removalBytes)). The shared runtime is removed when no optional engine remains.")
        }
    }
}

struct RestoreAdvancedControls: View {
    @Binding var options: UpscaleOptions
    var body: some View {
        LabeledContent("Base Engine") {
            Picker("Base Engine", selection: $options.restore.baseEngine) {
                Text("Auto · illustration / photo").tag(Optional<Preset>.none)
                ForEach([Preset.realCUGAN, .realSR, .realSRJPEG, .realESRGAN, .anime4k, .waifu2xArt, .waifu2xPhoto], id: \.self) {
                    Text($0.rawValue).tag(Optional($0))
                }
            }.pickerStyle(.menu).labelsHidden()
        }
        Toggle("Safety Check", isOn: $options.restore.safetyCheck)
            .help("Retries or skips AI results that add or move large parts of the image.")
        LabeledContent("Seed") {
            TextField("Seed", value: $options.restore.seed, format: .number.grouping(.never))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.callout)
            TextEditor(text: $options.restore.prompt).font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Restore Prompt")
            HStack {
                Spacer()
                Button("Reset Prompt") { options.restore.prompt = RestoreSettings.defaultPrompt }
                    .disabled(options.restore.prompt == RestoreSettings.defaultPrompt)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
