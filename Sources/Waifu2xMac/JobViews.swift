import SwiftUI
import UpscaleCore

struct JobThumbnail: View {
    let job: Job
    var size = CGSize(width: 56, height: 42)
    var cornerRadius: CGFloat = 7
    var contentMode: ContentMode = .fill
    var blurredFill = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MediaThumbnail(url: job.source, size: size, cornerRadius: cornerRadius, contentMode: contentMode,
                       blurredFill: blurredFill)
            .overlay {
                if case let .running(progress) = job.state {
                    Color.black.opacity(0.4).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    ProgressRing(value: progress).accessibilityLabel("Upscaling progress")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if size.width >= 60 && job.kind != .image {
                    Group {
                        if job.kind == .gif { Text("GIF").font(.caption2.bold()) }
                        else { Image(systemName: "play.fill").font(.caption2) }
                    }.padding(.horizontal, 4).padding(.vertical, 2).glassSurface(Capsule()).padding(3)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                switch job.state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(Color.accentColor).background(.white, in: Circle())
                        .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
                        .transition(reduceMotion ? .identity : .scale).padding(3).accessibilityLabel("Completed")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .padding(3).accessibilityLabel("Failed")
                default: EmptyView()
                }
            }
            .animation(reduceMotion ? nil : .spring, value: job.state.label)
    }
}

struct JobStatusLine: View {
    let workspace: Workspace
    let job: Job
    var showsMediaKind = false

    var body: some View {
        Text(subtitle).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            .help(error ?? subtitle).task(id: job.id) { await MediaMetadata.shared.load(job) }
    }

    private var subtitle: String {
        label + (showsMediaKind && job.kind != .image ? (job.kind == .gif ? " · GIF" : " · Video") : "")
    }

    var label: String {
        switch job.state {
        case let .running(progress): return "Upscaling… \(Int(progress * 100))%"
        case .completed:
            var text = job.result.map {
                ($0.dimensions.map { $0.label + " · " } ?? "") +
                    ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file)
            } ?? "Completed"
            if let note = job.restoreSummary.note(for: job.kind) { text += " · " + note }
            return text
        case .failed: return "Failed"
        case .waiting, .stopped:
            return (MediaMetadata.shared.sizes[job.id]?.label ?? job.kind.rawValue) + " · " +
                ByteCountFormatter.string(fromByteCount: Int64(job.byteCount), countStyle: .file) +
                (job.kind == .video && workspace.options.usesAI ? " · uses \(workspace.videoEngineName)" : "")
        }
    }

    private var error: String? { if case let .failed(error) = job.state { error } else { nil } }
    private var failed: Bool { error != nil }
}

struct JobStateIndicator: View {
    let job: Job

    var body: some View {
        switch job.state {
        case let .running(progress):
            HStack(spacing: 8) {
                ProgressRing(value: progress, size: 18).accessibilityLabel("Upscaling progress")
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).font(.caption.monospacedDigit())
            }
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case let .failed(error):
            Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).help(error)
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.quaternary, in: Capsule())
        case .stopped: Text("Stopped").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct JobActions: View {
    let workspace: Workspace
    let job: Job

    var body: some View {
        if case let .completed(output) = job.state {
            Button("Open Result") { NSWorkspace.shared.open(output) }.disabled(workspace.isExporting)
            Button("Show Result in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        }
        Button("Copy Path") {
            if case let .completed(output) = job.state { copy(output.path) }
            else { copy(job.source.path) }
        }.disabled(workspace.isExporting)
        if case let .failed(error) = job.state {
            Button("Copy Error") { copy(error) }.disabled(workspace.isExporting)
        }
        Button("Show Source in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
        switch job.state {
        case .completed, .failed, .stopped:
            Button("Queue Again") { workspace.queueAgain(job.id) }.disabled(workspace.isExporting)
        default: EmptyView()
        }
        Divider()
        Button("Remove from Batch", role: .destructive) { workspace.remove(job.id) }.disabled(workspace.isExporting)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
