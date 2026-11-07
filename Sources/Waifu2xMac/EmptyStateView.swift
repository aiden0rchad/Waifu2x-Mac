import SwiftUI

struct EmptyStateView: View {
    let workspace: Workspace
    let dropTarget: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            LightboxMark().scaleEffect(dropTarget ? 1.06 : 1)
            Text(dropTarget ? "Release to Add" : "Drop to Upscale")
                .font(.system(size: 30, weight: .semibold))
            Text("Images, GIFs and videos — upscaled on this Mac.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GlassGroup {
                HStack {
                    Button(action: workspace.chooseFiles) { Text("Choose Files…").frame(minWidth: 140) }
                        .prominentGlassButton()
                    Button(action: workspace.chooseInputFolder) { Text("Choose Folder…").frame(minWidth: 140) }
                        .glassButton()
                }.controlSize(.large)
            }.padding(.top, 8)
            if !workspace.recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(workspace.recent.prefix(4)), id: \.self) { url in
                            RecentExportTile(url: url)
                        }
                    }
                }.padding(.top, 20)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AmbientBackdrop(image: nil).ignoresSafeArea() }
        .animation(reduceMotion ? nil : .spring, value: dropTarget)
    }
}

private struct RecentExportTile: View {
    let url: URL
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            VStack(spacing: 4) {
                MediaThumbnail(url: url, size: CGSize(width: 96, height: 64), cornerRadius: 8)
                Text(url.deletingPathExtension().lastPathComponent).font(.caption2)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity)
            }.frame(width: 96)
        }.buttonStyle(.plain).help(url.lastPathComponent).accessibilityLabel(url.lastPathComponent)
            .scaleEffect(hovering && !reduceMotion ? 1.04 : 1)
            .animation(reduceMotion ? nil : .spring, value: hovering)
            .onHover { hovering = $0 }
    }
}

private struct LightboxMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * .pi / 4
            let dividerX = 66 + sin(phase) * 32
            Canvas { context, _ in
                let centre = CGPoint(x: 66, y: 66)
                let radius: CGFloat = 42
                let circle = CGRect(x: 24, y: 24, width: 84, height: 84)
                var right = context
                right.clip(to: Path(CGRect(x: dividerX, y: 0, width: 132 - dividerX, height: 132)))
                right.fill(Path(ellipseIn: circle), with: .color(.accentColor))
                var pixels = context
                pixels.clip(to: Path(CGRect(x: 0, y: 0, width: dividerX, height: 132)))
                for x in stride(from: 24, to: 108, by: 8) {
                    for y in stride(from: 24, to: 108, by: 8) {
                        let cell = CGRect(x: x, y: y, width: 8, height: 8)
                        let dx = cell.midX - centre.x, dy = cell.midY - centre.y
                        if dx * dx + dy * dy <= radius * radius {
                            pixels.fill(Path(cell), with: .color(.accentColor))
                        }
                    }
                }
                context.addFilter(.shadow(color: .black.opacity(0.3), radius: 1, y: 1))
                context.fill(Path(CGRect(x: dividerX - 0.5, y: 16, width: 1, height: 100)),
                             with: .color(.white.opacity(0.85)))
                context.fill(Path(ellipseIn: CGRect(x: dividerX - 5, y: 61, width: 10, height: 10)),
                             with: .color(.white.opacity(0.85)))
            }
        }
        .frame(width: 132, height: 132)
        .glassSurface(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .accessibilityHidden(true)
    }
}
