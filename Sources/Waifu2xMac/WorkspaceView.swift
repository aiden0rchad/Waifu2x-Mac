import SwiftUI
import UpscaleCore

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let delegate: AppDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTarget = false

    var body: some View {
        ZStack {
            if workspace.jobs.isEmpty {
                EmptyStateView(workspace: workspace, dropTarget: dropTarget)
            } else {
                populatedContent
            }
        }
        .overlay { dropHighlight }
        .toolbarBackgroundVisibility(workspace.page == .adjust || workspace.jobs.isEmpty ? .hidden : .automatic, for: .windowToolbar)
        .navigationTitle(workspace.jobs.isEmpty ? "Waifu2x-Mac" : workspace.selected?.source.lastPathComponent ?? "Waifu2x-Mac")
        .navigationSubtitle(workspace.jobs.isEmpty ? "" : subtitle)
        .toolbar {
            if workspace.jobs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Files", systemImage: "plus", action: workspace.chooseFiles)
                        .help("Add Files…").disabled(workspace.isExporting)
                }
            }
            if !workspace.jobs.isEmpty {
                ToolbarItem(placement: .principal) {
                    PageSteps(workspace: workspace).disabled(workspace.isExporting)
                }
                if workspace.page != .files {
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") {
                            workspace.page = Workspace.Page(rawValue: workspace.page.rawValue - 1) ?? .files
                        }.labelStyle(.iconOnly).help("Back").accessibilityLabel("Back")
                            .keyboardShortcut("[", modifiers: .command).disabled(workspace.isExporting)
                    }
                }
                if workspace.page != .export {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            workspace.page = Workspace.Page(rawValue: workspace.page.rawValue + 1) ?? .export
                        } label: {
                            HStack(spacing: 6) {
                                Text("Continue")
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }.foregroundStyle(.white)
                        }.accessibilityLabel("Continue")
                            .prominentGlassButton().tint(Color(nsColor: .controlAccentColor))
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(workspace.isExporting || (workspace.page == .engine && !workspace.selectedEngineInstalled))
                            .help(workspace.page == .engine && !workspace.selectedEngineInstalled
                                  ? "Download the AI engine first." : "Continue to the next page.")
                    }.independentToolbarBackground()
                } else {
                    ToolbarItem(placement: .primaryAction) { exportAction }
                        .independentToolbarBackground(!workspace.isExporting)
                }
                if workspace.page == .adjust {
                    ToolbarItem(placement: .primaryAction) {
                        Button(workspace.inspectorPresented ? "Hide Inspector" : "Show Inspector",
                               systemImage: "sidebar.right", action: workspace.toggleInspector)
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !workspace.isExporting else { return false }
            workspace.add(urls)
            return true
        } isTargeted: { dropTarget = $0 && !workspace.isExporting }
        .onAppear {
            delegate.connect { [workspace] urls in workspace.add(urls) }
            updateVisibility()
            refreshPreviewIfNeeded()
        }
        .task(id: workspace.backdropSource) {
            if let source = workspace.backdropSource { await MediaMetadata.shared.loadBackdrop(source) }
        }
        .onChange(of: workspace.jobs.isEmpty) { updateVisibility() }
        .onChange(of: workspace.page) {
            updateVisibility()
            refreshPreviewIfNeeded()
        }
        .onChange(of: workspace.inspectorPresented) {
            if workspace.jobs.isEmpty { workspace.inspectorPresented = false }
        }
        .onChange(of: workspace.selection) { refreshPreviewIfNeeded() }
        .onChange(of: workspace.options) { refreshPreviewIfNeeded() }
        .onChange(of: workspace.showsDetail) { refreshPreviewIfNeeded() }
        .onChange(of: workspace.isExporting) { _, exporting in
            if exporting { workspace.page = .export }
            else { refreshPreviewIfNeeded() }
        }
    }

    private var populatedContent: some View {
        ZStack {
            AmbientBackdrop(image: workspace.backdropImage, showsIdleLight: false).ignoresSafeArea()
            ZStack { pageContent.id(workspace.page).transition(.opacity) }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: workspace.page)
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch workspace.page {
        case .files: FilesPage(workspace: workspace)
        case .engine: EnginePage(workspace: workspace)
        case .adjust:
            HStack(spacing: 0) {
                CanvasView(workspace: workspace)
                if workspace.inspectorPresented {
                    HStack(spacing: 0) {
                        Divider()
                        InspectorView(workspace: workspace).frame(width: 310)
                            .scrollContentBackground(.hidden)
                            .background { Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: .top) }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // Only user toggles change the preference; page switches update visibility without animation.
            .animation(reduceMotion ? nil : .smooth, value: workspace.inspectorPreference)
        case .export: ExportPage(workspace: workspace)
        }
    }

    @ViewBuilder private var exportAction: some View {
        if workspace.isExporting {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressRing(value: workspace.batchProgress, size: 18)
                        .tint(Color(nsColor: .controlAccentColor)).accessibilityLabel("Export progress")
                    Text(workspace.batchProgress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }.padding(.horizontal, 12).padding(.vertical, 8)
                Button("Stop", systemImage: "stop.fill", action: workspace.stop)
                    .labelStyle(.iconOnly).glassButton().help("Stop").accessibilityLabel("Stop")
                    .disabled(workspace.isStopping)
            }
        } else if workspace.pending == 0 && workspace.hasRun {
            Button("Show in Finder", systemImage: "folder", action: workspace.revealCompleted).glassButton()
        } else {
            Button(action: workspace.requestExport) {
                Label("Export", systemImage: "square.and.arrow.up").foregroundStyle(.white)
            }.labelStyle(.titleAndIcon)
                .accessibilityLabel(workspace.hasRun ? "Export Remaining" : "Export")
                .prominentGlassButton().tint(Color(nsColor: .controlAccentColor))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!workspace.canRequestExport).help(workspace.exportHelp)
        }
    }

    @ViewBuilder private var dropHighlight: some View {
        if dropTarget {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2) }
                .padding(14).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func updateVisibility() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            workspace.inspectorPresented = !workspace.jobs.isEmpty && workspace.page == .adjust &&
                (workspace.inspectorPreference ?? true)
        }
    }

    private func refreshPreviewIfNeeded() {
        if workspace.page == .adjust && !workspace.jobs.isEmpty { workspace.refreshPreview() }
    }

    private var subtitle: String {
        if workspace.isExporting { return workspace.isStopping ? "Stopping…" : workspace.progressLabel }
        if let notice = workspace.notice { return notice }
        guard !workspace.jobs.isEmpty else { return "" }
        return "\(workspace.jobs.count) \(workspace.jobs.count == 1 ? "file" : "files") · \(workspace.options.sizeLabel)"
    }
}
