import SwiftUI
import UpscaleCore

struct CanvasView: View {
    @Bindable var workspace: Workspace
    @State private var split = 0.5
    @State private var displayedPreview: MediaPreview?
    @State private var displayedSource: URL?
    @State private var aiPreviewSource: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var canvasFocused: Bool
    @State private var recentFocus = false
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let preview = displayedPreview {
                CompareView(preview: preview, split: $split, focus: workspace.detailFocus,
                            showsFocus: recentFocus,
                            pickFocus: displayedSource == workspace.selection && !workspace.isLoadingPreview &&
                                workspace.detailAvailable && !workspace.isGeneratingAI && !workspace.isExporting
                                ? { canvasFocused = true; workspace.setDetailFocus($0) } : nil,
                            isGeneratingAI: workspace.isGeneratingAI)
                    .id(displayedSource).transition(.opacity)
            } else if workspace.isLoadingPreview || (workspace.selection != nil && workspace.previewError == nil) {
                ProgressView().controlSize(.small)
            } else if let error = workspace.previewError {
                ContentUnavailableView("Can't Preview", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView("Select a File", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable(workspace.detailAvailable && !workspace.showsDetail)
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard !workspace.showsDetail, workspace.detailAvailable, !workspace.isGeneratingAI,
                  !workspace.isExporting, let input = workspace.preview?.input else { return .ignored }
            let focus = workspace.detailFocus
            let dx = 32 / Double(input.width), dy = 32 / Double(input.height)
            switch press.key {
            case .leftArrow: workspace.setDetailFocus(CGPoint(x: focus.x - dx, y: focus.y))
            case .rightArrow: workspace.setDetailFocus(CGPoint(x: focus.x + dx, y: focus.y))
            case .upArrow: workspace.setDetailFocus(CGPoint(x: focus.x, y: focus.y - dy))
            case .downArrow: workspace.setDetailFocus(CGPoint(x: focus.x, y: focus.y + dy))
            default: return .ignored
            }
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Reserve space so the floating bar never covers the image or its labels.
            Color.clear.frame(height: 60)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if workspace.jobs.count > 1 { Color.clear.frame(height: 52) }
        }
        .overlay(alignment: .top) {
            if workspace.jobs.count > 1 {
                Filmstrip(workspace: workspace).padding(.horizontal, 16).padding(.top, 12)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if workspace.preview != nil, let error = workspace.previewError {
                    Label { Text(error).foregroundStyle(.primary).textSelection(.enabled) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8).glassSurface(Capsule())
                }
                controls
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }
        .onChange(of: workspace.selection) {
            aiPreviewSource = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { split = 0.5 }
        }
        .onAppear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedPreview = workspace.selectedPreview
                displayedSource = workspace.selectedPreview == nil ? nil : workspace.selection
            }
        }
        .onChange(of: workspace.preview.map { ObjectIdentifier($0.after) }) { updateDisplayedPreview() }
        .onChange(of: workspace.isLoadingPreview) { updateDisplayedPreview() }
        .onChange(of: workspace.isGeneratingAI) {
            if workspace.isGeneratingAI { aiPreviewSource = workspace.selection }
            else if workspace.preview?.method != OptionalEngine.fluxKleinRestore.name { aiPreviewSource = nil }
        }
        .task(id: workspace.preview?.method) {
            guard workspace.preview?.method == OptionalEngine.fluxKleinRestore.name,
                  aiPreviewSource == workspace.selection, aiPreviewSource != nil else { return }
            aiPreviewSource = nil
            guard !reduceMotion else { split = 0.5; return }
            let source = workspace.selection
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { split = 1 }
            // Give the original-only frame time to render before starting the reveal.
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            guard workspace.selection == source else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.9)) { split = 0.5 }
        }
        .onChange(of: workspace.detailFocus) {
            focusTask?.cancel()
            recentFocus = true
            focusTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                recentFocus = false
            }
        }
        .onDisappear {
            focusTask?.cancel()
            recentFocus = false
        }
    }

    private func updateDisplayedPreview() {
        guard let preview = workspace.selectedPreview else {
            if !workspace.isLoadingPreview { displayedPreview = nil; displayedSource = nil }
            return
        }
        let animation: Animation? = !reduceMotion && displayedSource != workspace.selection ? .easeInOut(duration: 0.25) : nil
        withAnimation(animation) {
            displayedPreview = preview
            displayedSource = workspace.selection
        }
    }

    private var controls: some View {
        GlassGroup {
            ViewThatFits(in: .horizontal) {
                controlRow
                ScrollView(.horizontal) { controlRow }.scrollIndicators(.hidden)
            }
            .controlSize(.regular)
            .padding(.horizontal, 6).frame(minHeight: 44)
            .glassSurface(Capsule())
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            if workspace.selected?.kind == .video && !workspace.detailAvailable {
                Text("Video preview").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Preview Mode", selection: $workspace.showsDetail) {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right").tag(false)
                    Label("Actual Pixels", systemImage: "1.magnifyingglass").tag(true)
                }
                .pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().fixedSize()
                .disabled(!workspace.detailAvailable || workspace.isGeneratingAI || workspace.isExporting)
                .help("Click the image in Fit to choose the 1:1 region.")
            }
            barDivider
            HStack(spacing: 6) {
                Text(inputDimensions)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityLabel("to")
                Text(outputDimensions)
            }.font(.callout.monospacedDigit()).fixedSize().contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth, value: inputDimensions + outputDimensions)
            if workspace.options.usesAI && (workspace.selected?.kind == .image || workspace.selected?.kind == .gif) {
                barDivider
                ZStack(alignment: .leading) {
                    ZStack {
                        aiIdle
                        aiGenerating(progress: 1)
                        aiDone
                    }.hidden().accessibilityHidden(true)
                    if workspace.isGeneratingAI {
                        aiGenerating(progress: workspace.aiPreviewProgress)
                    } else if workspace.preview?.method == OptionalEngine.fluxKleinRestore.name {
                        aiDone
                    } else {
                        aiIdle
                    }
                }.fixedSize()
            }
        }
    }

    private var aiIdle: some View {
        Button("Preview AI", systemImage: "sparkles", action: workspace.generateAIPreview)
            .prominentGlassButton().controlSize(.regular)
            .disabled(!workspace.canPreviewAI).help(aiHelp)
    }

    private func aiGenerating(progress: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityLabel("AI preview progress")
            Text("Restoring \(Int(progress * 100))%").font(.callout.monospacedDigit())
            Button("Cancel", systemImage: "xmark", action: workspace.cancelAIPreview)
                .labelStyle(.iconOnly).glassButton().help("Cancel").accessibilityLabel("Cancel")
        }
    }

    private var aiDone: some View {
        Label("AI Restore", systemImage: "checkmark.seal.fill")
            .font(.callout).foregroundStyle(.secondary).help(aiHelp)
    }

    private var barDivider: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 18)
    }

    private var inputDimensions: String {
        guard let preview = workspace.preview ?? displayedPreview else { return "—" }
        return preview.detail.map { "\(Int($0.rect.width)) × \(Int($0.rect.height))" } ?? preview.input.label
    }

    private var outputDimensions: String {
        guard let preview = workspace.preview ?? displayedPreview else { return "—" }
        return (preview.detail?.output ?? preview.output).label
    }

    private var aiHelp: String {
        let time = workspace.selected?.kind == .gif ? "About 25 s per unique frame" : "About 25 s"
        return workspace.preview?.restoreOutcome?.note.map { $0 + " · " + time } ?? time
    }
}
