import SwiftUI

struct Filmstrip: View {
    @Bindable var workspace: Workspace

    var body: some View {
        ViewThatFits(in: .horizontal) {
            thumbnails
            ScrollView(.horizontal) { thumbnails }.scrollIndicators(.hidden)
        }
        .padding(6).glassSurface(Capsule()).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain).accessibilityLabel("Files")
    }

    private var thumbnails: some View {
        HStack(spacing: 6) {
            ForEach(Array(workspace.jobs.prefix(12))) { job in
                Button { workspace.selection = job.id } label: {
                    MediaThumbnail(url: job.source, size: CGSize(width: 36, height: 28), cornerRadius: 6)
                        .overlay {
                            if workspace.selection == job.id {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                            }
                        }
                }.buttonStyle(.plain).help(job.source.lastPathComponent).accessibilityLabel(job.source.lastPathComponent)
                    .accessibilityAddTraits(workspace.selection == job.id ? .isSelected : [])
            }
        }
    }
}
