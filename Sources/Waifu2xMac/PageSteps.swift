import SwiftUI

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

struct PageSteps: View {
    @Bindable var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        GlassGroup {
            HStack(spacing: 8) {
                ForEach(Workspace.Page.allCases, id: \.self) { page in
                    if page != .files {
                        Image(systemName: "chevron.right").font(.caption2.weight(.light))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    Button { workspace.page = page } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                if workspace.page == page {
                                    if reduceMotion { Circle().fill(Color(nsColor: .controlAccentColor)) }
                                    else {
                                        Circle().fill(Color(nsColor: .controlAccentColor))
                                            .matchedGeometryEffect(id: "currentStep", in: highlight)
                                    }
                                } else if page.rawValue < workspace.page.rawValue {
                                    Circle().fill(.secondary.opacity(0.35))
                                } else { Circle().strokeBorder(.secondary, lineWidth: 1) }
                                if page.rawValue < workspace.page.rawValue {
                                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                                } else {
                                    Text("\(page.rawValue + 1)").font(.caption.weight(.semibold))
                                        .foregroundStyle(workspace.page == page ? Color.white : Color.secondary)
                                }
                            }.frame(width: 20, height: 20)
                            Text(page.title).font(.callout.weight(workspace.page == page ? .semibold : .regular))
                                .foregroundStyle(workspace.page == page ? .primary : .secondary).lineLimit(1)
                        }.padding(.vertical, 6).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel(page.title)
                        .accessibilityValue("Step \(page.rawValue + 1) of 4")
                        .accessibilityAddTraits(workspace.page == page ? .isSelected : [])
                }
            }.padding(.horizontal, 12).padding(.vertical, 2).glassSurface(Capsule())
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: workspace.page)
        }
    }
}
