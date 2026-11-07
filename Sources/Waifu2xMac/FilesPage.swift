import SwiftUI
import UpscaleCore

struct FilesPage: View {
    @Bindable var workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)], spacing: 20) {
                    ForEach(workspace.jobs) { job in FileCard(workspace: workspace, job: job) }
                    addMore
                }
            }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softTopScrollEdge()
        .task(id: workspace.jobs.map(\.id)) {
            for job in workspace.jobs { await MediaMetadata.shared.load(job) }
        }
        .onDeleteCommand {
            if let selection = workspace.selection { workspace.remove(selection) }
        }
    }

    private var header: some View {
        PageHeader(title: "\(workspace.jobs.count) \(workspace.jobs.count == 1 ? "File" : "Files")", subtitle: summary) {
            GlassGroup {
                HStack {
                    Button("Add Files…", systemImage: "plus", action: workspace.chooseFiles).glassButton()
                    Button("Add Folder…", systemImage: "folder.badge.plus", action: workspace.chooseInputFolder).glassButton()
                }.controlSize(.large)
            }.disabled(workspace.isExporting)
        }
    }

    private var summary: String {
        let kinds: [(MediaKind, String, String)] = [(.image, "image", "images"), (.gif, "GIF", "GIFs"), (.video, "video", "videos")]
        var parts = kinds.compactMap { kind, singular, plural -> String? in
            let count = workspace.jobs.filter { $0.kind == kind }.count
            return count == 0 ? nil : "\(count) \(count == 1 ? singular : plural)"
        }
        let bytes = MediaMetadata.shared.byteCounts
        if workspace.jobs.allSatisfy({ bytes[$0.id] != nil }) {
            let total = workspace.jobs.reduce(Int64(0)) { $0 + Int64(bytes[$1.id] ?? 0) }
            parts.append(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private var addMore: some View {
        Button(action: workspace.chooseFiles) {
            VStack(spacing: 10) {
                Color.clear.aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { Image(systemName: "plus").font(.largeTitle).foregroundStyle(.secondary) }
                Text("Add More").font(.body.weight(.medium))
                Text("Images, GIFs or videos").font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity)
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [6, 5])) }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel("Add More").disabled(workspace.isExporting)
    }
}

private struct FileCard: View {
    let workspace: Workspace
    let job: Job
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var selected: Bool { workspace.selection == job.id }

    var body: some View {
        Button { workspace.selection = job.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear.aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            JobThumbnail(job: job, size: geometry.size, cornerRadius: 12, contentMode: .fit, blurredFill: true)
                        }
                    }
                Text(job.source.lastPathComponent).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(job.source.lastPathComponent)
                JobStatusLine(workspace: workspace, job: job).lineLimit(1).truncationMode(.middle)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                    }
                }.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain).disabled(workspace.isExporting)
        .simultaneousGesture(TapGesture(count: 2).onEnded { adjust() })
        .accessibilityElement(children: .ignore).accessibilityLabel(job.source.lastPathComponent)
        .accessibilityValue(JobStatusLine(workspace: workspace, job: job).label)
        .accessibilityHint("Double-click to adjust this file.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Adjust") { adjust() }
        .overlay(alignment: .topTrailing) {
            if hovering && !workspace.isExporting {
                Button("Remove \(job.source.lastPathComponent)", systemImage: "xmark.circle.fill") { workspace.remove(job.id) }
                    .labelStyle(.iconOnly).buttonStyle(.plain).font(.title3)
                    .foregroundStyle(.white).background(.black.opacity(0.55), in: Circle()).padding(6)
                    .help("Remove \(job.source.lastPathComponent)").accessibilityLabel("Remove \(job.source.lastPathComponent)")
            }
        }
        .contextMenu { JobActions(workspace: workspace, job: job) }
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .spring, value: hovering)
        .onHover { hovering = $0 }
    }

    private func adjust() {
        guard !workspace.isExporting else { return }
        workspace.selection = job.id
        workspace.page = .adjust
    }
}
