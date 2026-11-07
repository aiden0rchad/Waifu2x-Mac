import AppKit
import AVFoundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import UpscaleCore

struct Job: Identifiable {
    let source: URL
    let kind: MediaKind
    var state: State = .waiting
    var result: ResultDetails?
    var restoreSummary = RestoreSummary()
    var id: URL { source }
    let byteCount: Int

    init(source: URL, kind: MediaKind) {
        self.source = source
        self.kind = kind
        byteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    struct ResultDetails: Sendable {
        let dimensions: Dimensions?
        let byteCount: Int
        let duration: TimeInterval

        static func read(_ output: URL, kind: MediaKind, duration: TimeInterval) async -> Self {
            let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var dimensions: Dimensions?
            if kind == .video {
                let asset = AVURLAsset(url: output)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
                    dimensions = Dimensions(width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
                }
            } else if let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int {
                dimensions = Dimensions(width: width, height: height)
            }
            return Self(dimensions: dimensions, byteCount: bytes, duration: duration)
        }
    }

    enum State {
        case waiting, running(Double), completed(URL), failed(String), stopped

        var label: String {
            switch self {
            case .waiting: "Ready"
            case let .running(progress): "\(Int(progress * 100))%"
            case .completed: "Done"
            case .failed: "Failed"
            case .stopped: "Stopped"
            }
        }
    }
}

struct SavedPreset: Codable, Identifiable {
    let name: String
    let options: UpscaleOptions
    var id: String { name }
}

@MainActor @Observable
final class Workspace {
    enum Page: Int, CaseIterable {
        case files, engine, adjust, export

        var title: String { ["Files", "Engine", "Adjust", "Export"][rawValue] }
        var symbol: String { ["photo.on.rectangle", "cpu", "slider.horizontal.3", "square.and.arrow.up"][rawValue] }
    }

    var page: Page = .files
    let engineLibrary = OptionalEngineLibrary()
    var jobs: [Job] = [] { didSet { if jobs.isEmpty { page = .files } } }
    var selection: Job.ID?
    var options = UpscaleOptions() { didSet { storeSettings() } }
    var folder: URL? { didSet { storeSettings() } }
    var besideOriginals = true { didSet { storeSettings() } }
    var keepAwake = true { didSet { storeSettings() } }
    var revealWhenDone = false { didSet { storeSettings() } }
    var presets: [SavedPreset] = []
    var recent: [URL] = []
    var preview: MediaPreview?
    var previewError: String?
    var isLoadingPreview = false
    var isGeneratingAI = false
    var aiPreviewProgress: Double = 0
    var references: [ReferenceImage] = []
    @ObservationIgnored private let previewUpscaler = Upscaler()
    var inspectorPresented = false
    var inspectorPreference: Bool?
    var showsDetail = false
    var detailFocus = CGPoint(x: 0.5, y: 0.5)
    var notice: String?
    var activeID: Job.ID?
    var isStopping = false
    var hasRun = false
    var elapsed: TimeInterval?
    var batchElapsed: TimeInterval = 0
    private var batchIDs: Set<URL> = []

    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var previewSource: URL?
    @ObservationIgnored private var previewGeneration = UUID()
    @ObservationIgnored private var previewCache: [(key: PreviewKey, value: MediaPreview)] = []

    private struct PreviewKey: Equatable, Sendable {
        let source: URL
        let options: UpscaleOptions
        let focus: CGPoint?
        var references: [ReferenceImage] = []
        var ai = false
    }

    var detailAvailable: Bool { selected != nil && !(selected?.kind == .video && options.videoEngine.isTemporal) }
    private var previewKey: PreviewKey? {
        selection.map { PreviewKey(source: $0, options: options, focus: showsDetail && detailAvailable ? detailFocus : nil,
                                  references: references) }
    }

    var selected: Job? { jobs.first { $0.id == selection } }
    var selectedPreview: MediaPreview? { previewSource == selection ? preview : nil }
    var backdropSource: URL? { selection ?? jobs.first?.id }
    var backdropImage: CGImage? {
        selectedPreview?.before ?? backdropSource.flatMap { MediaMetadata.shared.backdrops[$0] }
    }
    var selectedEngineAppearance: EngineAppearance {
        if usesOnlyVideoModel { return options.videoEngine.appearance }
        return options.usesAI ? .restore : options.preset.appearance
    }
    var isExporting: Bool { activeID != nil }
    var batchPosition: String { "\(min(batchFinished + 1, batchIDs.count)) of \(batchIDs.count)" }
    var completed: Int { jobs.filter { if case .completed = $0.state { true } else { false } }.count }
    var pending: Int { jobs.count - completed }
    var batchFinished: Int {
        jobs.filter { job in
            guard batchIDs.contains(job.id) else { return false }
            switch job.state {
            case .completed, .failed: return true
            default: return false
            }
        }.count
    }
    var batchProgress: Double {
        guard !batchIDs.isEmpty else { return 0 }
        let fraction = jobs.reduce(0.0) { value, job in
            if batchIDs.contains(job.id), case let .running(progress) = job.state { return value + progress }
            return value
        }
        return min(1, (Double(batchFinished) + fraction) / Double(batchIDs.count))
    }
    var progressLabel: String {
        var label = "Exporting \(min(batchFinished + 1, batchIDs.count)) of \(batchIDs.count) · \(Int(batchProgress * 100))%"
        if batchProgress > 0.05, batchElapsed > 5 {
            label += " · about \(Self.durationLabel(batchElapsed * (1 - batchProgress) / batchProgress)) left"
        }
        return label
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(Int((seconds / 5).rounded()) * 5) s" }
        let minutes = Int((seconds / 60).rounded())
        if seconds < 3600 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
    var hasVideo: Bool { jobs.contains { $0.kind == .video } }
    var hasGIF: Bool { jobs.contains { $0.kind == .gif } }
    var aiUnsupportedCount: Int { options.usesAI ? jobs.filter { $0.kind == .video }.count : 0 }
    var videoEngineName: String { options.videoEngine == .spatial ? options.preset.rawValue : options.videoEngine.rawValue }
    var batchEngineName: String {
        if options.usesAI {
            return options.engineName + (hasVideo ? " + \(videoEngineName) for video" : "")
        }
        if usesOnlyVideoModel { return videoEngineName }
        return options.engineName + (hasVideo && options.videoEngine != .spatial ? " / \(videoEngineName)" : "")
    }
    var activeMotion: MotionEngine {
        if hasGIF && !options.usesAI && options.motionEngine == .rife { return .rife }
        return hasVideo && options.interpolatesMotion ? options.motionEngine : .off
    }
    var usesOnlyVideoModel: Bool {
        hasVideo && options.videoEngine != .spatial && jobs.allSatisfy { $0.kind == .video }
    }
    var destinationLabel: String { besideOriginals ? "Beside originals" : folder?.lastPathComponent ?? "Choose a folder" }
    var invalidCustomSize: Bool {
        options.size == .custom && (options.customWidth < 1 || options.customHeight < 1)
    }
    var selectedEngineInstalled: Bool {
        guard let id = options.optionalEngineID,
              let engine = OptionalEngine.all.first(where: { $0.id == id }) else { return true }
        return engineLibrary[engine].installed
    }
    var canRequestExport: Bool {
        !isExporting && pending > 0 && !invalidCustomSize && selectedEngineInstalled
    }
    var canExport: Bool { canRequestExport && (besideOriginals || folder != nil) }
    var exportHelp: String {
        if invalidCustomSize { return "Enter a width and height." }
        if !selectedEngineInstalled { return "Download the AI engine first." }
        return "Export the batch."
    }
    var canPreviewAI: Bool {
        options.usesAI && (selected?.kind == .image || selected?.kind == .gif) &&
            !isExporting && !isLoadingPreview && !isGeneratingAI && selectedEngineInstalled && !invalidCustomSize
    }

    func requestExport() {
        guard canRequestExport else { return }
        if !besideOriginals && folder == nil { chooseFolder() }
        if canExport { export() }
    }

    func toggleInspector() {
        guard !jobs.isEmpty else { return }
        if page != .adjust {
            page = .adjust
            inspectorPresented = true
        } else { inspectorPresented.toggle() }
        inspectorPreference = inspectorPresented
    }

    func revealCompleted() {
        let outputs = jobs.compactMap { job -> URL? in
            if case let .completed(url) = job.state { return url }
            return nil
        }
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    init() {
        let defaults = UserDefaults.standard
        let settings = WorkspaceSettings.restore(from: defaults.data(forKey: "workspaceSettings"))
        options = settings.options
        folder = settings.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        besideOriginals = settings.besideOriginals
        keepAwake = settings.keepAwake
        revealWhenDone = settings.revealWhenDone
        if let data = defaults.data(forKey: "savedPresets"),
           let saved = try? JSONDecoder().decode([SavedPreset].self, from: data) { presets = saved }
        recent = (defaults.stringArray(forKey: "recentOutputs") ?? [])
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func storeSettings() {
        var settings = WorkspaceSettings()
        settings.options = options
        settings.folderPath = folder?.path
        settings.besideOriginals = besideOriginals
        settings.keepAwake = keepAwake
        settings.revealWhenDone = revealWhenDone
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "workspaceSettings")
        }
    }

    func chooseFiles() {
        let picker = NSOpenPanel()
        picker.title = "Add media"
        picker.allowedContentTypes = [.image, .movie]
        picker.allowsMultipleSelection = true
        if picker.runModal() == .OK { add(picker.urls) }
    }

    func chooseInputFolder() {
        let picker = NSOpenPanel()
        picker.title = "Add a folder of media"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        if picker.runModal() == .OK { add(picker.urls) }
    }

    func add(_ urls: [URL]) {
        guard !isExporting else { return }
        var known = Set(jobs.map(\.id))
        var skipped = 0
        for url in urls where url.isFileURL {
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let items = FileManager.default.enumerator(at: file, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let item as URL in items {
                    if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                       let kind = MediaKind(url: item), known.insert(item).inserted {
                        jobs.append(Job(source: item, kind: kind))
                    }
                }
            } else if let kind = MediaKind(url: file) {
                if known.insert(file).inserted { jobs.append(Job(source: file, kind: kind)) }
            } else {
                skipped += 1
            }
        }
        notice = skipped > 0 ? "\(skipped) unsupported \(skipped == 1 ? "file" : "files") skipped." : nil
        if selection == nil { selection = jobs.first?.id }
        if jobs.isEmpty && notice == nil { notice = "No supported media found." }
    }

    func remove(_ id: Job.ID) {
        guard !isExporting else { return }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
    }

    func queueAgain(_ id: Job.ID) {
        guard !isExporting else { return }
        setStatus(id, .waiting)
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose an output folder"
        picker.prompt = "Choose"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.directoryURL = folder
        if picker.runModal() == .OK {
            folder = picker.url
            besideOriginals = false
        }
    }

    func savePreset(_ rawName: String) {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        presets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        presets.append(SavedPreset(name: name, options: options))
        storePresets()
    }

    func deletePreset(_ preset: SavedPreset) {
        presets.removeAll { $0.id == preset.id }
        storePresets()
    }

    private func storePresets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "savedPresets")
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: "recentOutputs")
    }

    func startOver() {
        guard !isExporting else { return }
        jobs = []
        selection = nil
        previewTask?.cancel()
        preview = nil
        previewError = nil
        previewCache = []
        references = []
        let upscaler = previewUpscaler
        Task { await upscaler.clearAIPreview() }
        isGeneratingAI = false
        previewSource = nil
        notice = nil
        hasRun = false
        elapsed = nil
        batchIDs = []
        batchElapsed = 0
    }

    func refreshPreview() {
        previewTask?.cancel()
        isGeneratingAI = false
        aiPreviewProgress = 0
        previewGeneration = UUID()
        let generation = previewGeneration
        preview = nil
        previewError = nil
        guard let selection, !isExporting else {
            isLoadingPreview = false
            return
        }
        if previewSource != selection {
            previewSource = selection
            detailFocus = CGPoint(x: 0.5, y: 0.5)
            showsDetail = false
        }
        if !detailAvailable { showsDetail = false }
        guard let key = previewKey else { return }
        var aiKey = key
        aiKey.ai = true
        preview = previewCache.first { $0.key == aiKey }?.value ?? previewCache.first { $0.key == key }?.value
        isLoadingPreview = preview == nil
        var keys = [key]
        if detailAvailable {
            keys.append(PreviewKey(source: selection, options: options, focus: key.focus == nil ? detailFocus : nil, references: references))
        }
        let missing = keys.filter { key in
            var desired = key
            desired.ai = key.options.usesAI
            return !previewCache.contains { $0.key == desired }
        }
        let baseCached = keys.filter { key in previewCache.contains { $0.key == key } }
        let upscaler = previewUpscaler
        previewTask = Task.detached { [weak self] in
            for baseKey in missing {
                var key = baseKey
                do {
                    // Coalesce focus drags before starting model inference.
                    if key.focus != nil { try await Task.sleep(for: .milliseconds(150)) }
                    if key.options.usesAI { key.ai = await upscaler.hasAIPreview(key.source, options: key.options,
                        references: key.references) }
                    if !key.ai, baseCached.contains(key) { continue }
                    let result = try await upscaler.preview(key.source, options: key.options, focus: key.focus,
                        generateAI: key.ai, references: key.references)
                    try Task.checkCancellation()
                    await self?.finishPreview(key: key, generation: generation, result: .success(result))
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.finishPreview(key: key, generation: generation, result: .failure(error))
                }
            }
        }
    }

    func generateAIPreview() {
        guard canPreviewAI, var key = previewKey else { return }
        key.ai = true
        if let cached = previewCache.first(where: { $0.key == key }) { preview = cached.value; return }
        previewTask?.cancel()
        previewGeneration = UUID()
        let generation = previewGeneration
        let request = key
        let upscaler = previewUpscaler
        isGeneratingAI = true
        aiPreviewProgress = 0
        previewError = nil
        previewTask = Task.detached { [weak self] in
            do {
                let result = try await upscaler.preview(request.source, options: request.options,
                    focus: request.focus, generateAI: true, references: request.references) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == generation else { return }
                        self.aiPreviewProgress = progress
                    }
                }
                try Task.checkCancellation()
                await self?.finishPreview(key: request, generation: generation, result: .success(result))
            } catch {
                guard !Task.isCancelled else { return }
                await self?.finishPreview(key: request, generation: generation, result: .failure(error))
            }
        }
    }

    func cancelAIPreview() { refreshPreview() }

    func chooseReferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addReferences(panel.urls) }
    }

    func addReferences(_ urls: [URL]) {
        guard !isExporting else { return }
        for url in urls where url.isFileURL && MediaKind(url: url) == .image && !references.contains(where: { $0.url == url }) {
            guard references.count < 4 else { notice = "Use up to four reference images."; break }
            references.append(ReferenceImage(url: url))
        }
        refreshPreview()
    }

    func removeReference(_ url: URL) {
        guard !isExporting else { return }
        references.removeAll { $0.url == url }
        refreshPreview()
    }

    func setReferenceCrop(_ crop: CGRect?, for url: URL) {
        guard !isExporting, let index = references.firstIndex(where: { $0.url == url }) else { return }
        references[index].crop = crop
        refreshPreview()
    }

    func setDetailFocus(_ focus: CGPoint) {
        guard detailAvailable, !isExporting, focus.x.isFinite, focus.y.isFinite else { return }
        let point = CGPoint(x: min(1, max(0, focus.x)), y: min(1, max(0, focus.y)))
        guard point != detailFocus else { return }
        detailFocus = point
        refreshPreview()
    }

    private func finishPreview(key: PreviewKey, generation: UUID, result: Result<MediaPreview, Error>) {
        guard previewGeneration == generation, selection == key.source, options == key.options,
              references == key.references, !isExporting else { return }
        if case let .success(value) = result {
            previewCache.removeAll { $0.key == key }
            previewCache.append((key, value))
            if previewCache.count > 8 { previewCache.removeFirst() }
        }
        var current = previewKey
        current?.ai = key.ai
        guard current == key else { return }
        if key.ai { isGeneratingAI = false }
        if !key.ai, preview?.method == OptionalEngine.fluxKleinRestore.name { return }
        isLoadingPreview = false
        switch result {
        case let .success(value): preview = value
        case let .failure(error): previewError = error.localizedDescription
        }
    }

    func export() {
        guard canExport else { return }
        let inputs: [URL] = jobs.compactMap { job in
            if case .completed = job.state { return nil }
            return job.source
        }
        guard let first = inputs.first else { return }
        batchIDs = Set(inputs)
        for index in jobs.indices where batchIDs.contains(jobs[index].id) {
            jobs[index].state = .waiting
            jobs[index].result = nil
        }
        batchElapsed = 0
        let batchStart = Date()
        ExportFeedback.shared.begin()
        ExportFeedback.shared.update(progress: 0, remaining: inputs.count)
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.batchElapsed = Date().timeIntervalSince(batchStart)
            }
        }
        previewTask?.cancel()
        isLoadingPreview = false
        isGeneratingAI = false
        activeID = first
        notice = nil
        hasRun = true
        elapsed = nil
        let options = options
        let references = references
        let destination = besideOriginals ? nil : folder
        let keepAwake = keepAwake
        let revealWhenDone = revealWhenDone
        exportTask = Task.detached { [weak self] in
            let start = Date()
            let activity = keepAwake ? ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "Exporting media"
            ) : nil
            defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
            let upscaler = Upscaler()
            var outputs: [URL] = []
            var failures = 0
            for source in inputs {
                guard !Task.isCancelled else { break }
                await self?.setStatus(source, .running(0))
                let fileStart = Date()
                do {
                    let gate = ProgressGate()
                    let folder = destination ?? source.deletingLastPathComponent()
                    let result = try await upscaler.export(source, to: folder, options: options, references: references,
                        restoreSummary: { [weak self] summary in await self?.setRestoreSummary(source, summary) }) { [weak self] value in
                        guard gate.shouldReport(value) else { return }
                        Task { @MainActor in self?.updateProgress(source, value) }
                    }
                    outputs.append(result)
                    let details = await Job.ResultDetails.read(result, kind: MediaKind(url: source) ?? .image,
                                                               duration: Date().timeIntervalSince(fileStart))
                    await self?.complete(source, output: result, details: details)
                } catch {
                    if Task.isCancelled {
                        await self?.setStatus(source, .stopped)
                        break
                    }
                    failures += 1
                    await self?.setStatus(source, .failed(error.localizedDescription))
                }
            }
            let reveal = revealWhenDone && !Task.isCancelled
            await self?.finishExport(outputs: outputs, failed: failures, elapsed: Date().timeIntervalSince(start),
                                     reveal: reveal, stopped: Task.isCancelled)
        }
    }

    func stop() {
        guard isExporting else { return }
        isStopping = true
        exportTask?.cancel()
    }

    private func updateProgress(_ source: URL, _ progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == source }),
              case let .running(previous) = jobs[index].state, progress > previous else { return }
        jobs[index].state = .running(progress)
        ExportFeedback.shared.update(progress: batchProgress, remaining: batchIDs.count - batchFinished)
    }

    private func complete(_ source: URL, output: URL, details: Job.ResultDetails) {
        guard let index = jobs.firstIndex(where: { $0.id == source }) else { return }
        jobs[index].result = details
        setStatus(source, .completed(output))
    }

    private func setRestoreSummary(_ source: URL, _ summary: RestoreSummary) {
        guard let index = jobs.firstIndex(where: { $0.id == source }) else { return }
        jobs[index].restoreSummary = summary
    }

    private func setStatus(_ source: URL, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == source }) else { return }
        if case .running = state { activeID = source }
        jobs[index].state = state
        if isExporting {
            ExportFeedback.shared.update(progress: batchProgress, remaining: batchIDs.count - batchFinished)
        }
    }

    private func finishExport(outputs: [URL], failed: Int, elapsed: TimeInterval, reveal: Bool, stopped: Bool) {
        clockTask?.cancel()
        clockTask = nil
        batchElapsed = elapsed
        ExportFeedback.shared.finish(exported: outputs.count, failed: failed, stopped: stopped)
        activeID = nil
        isStopping = false
        exportTask = nil
        self.elapsed = elapsed
        if !outputs.isEmpty {
            let added = Set(outputs)
            recent = Array((outputs.reversed() + recent.filter { !added.contains($0) }).prefix(8))
            UserDefaults.standard.set(recent.map(\.path), forKey: "recentOutputs")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
    }
}

private final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = -1

    func shouldReport(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = Int(progress * 100)
        guard value > percent else { return false }
        percent = value
        return true
    }
}
