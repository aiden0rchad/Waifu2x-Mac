import SwiftUI
import UpscaleCore

struct CompareView: View {
    let preview: MediaPreview
    @Binding var split: Double
    let focus: CGPoint
    let showsFocus: Bool
    let pickFocus: ((CGPoint) -> Void)?
    var isGeneratingAI = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggingSplit: Bool?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let ratio = CGFloat(preview.after.width) / CGFloat(preview.after.height)
            let width = min(geometry.size.width - 80, (geometry.size.height - 80) * ratio)
            if width > 0 {
                if preview.detail != nil {
                    ScrollView([.horizontal, .vertical]) {
                        comparison(width: CGFloat(preview.after.width) / displayScale,
                                   height: CGFloat(preview.after.height) / displayScale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .defaultScrollAnchor(.center)
                    .accessibilityLabel("Detail comparison at actual export pixels")
                } else {
                    comparison(width: width, height: width / ratio)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false) }
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.detail == nil ? "Whole image comparison" : "Detail at actual export pixels")
        .accessibilityHint("Use the slider to compare. In Whole image, click or use arrow keys to move the detail region.")
    }

    private func comparison(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Canvas { context, size in
                let tile = 12.0
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .style(.quaternary))
                for row in 0..<Int(ceil(size.height / tile)) {
                    for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: Double(column) * tile, y: Double(row) * tile,
                                                 width: tile, height: tile)), with: .style(.quinary))
                    }
                }
            }.accessibilityHidden(true)
            Image(decorative: preview.after, scale: 1).resizable()
                .interpolation(preview.detail == nil ? .high : .none)
                .mask(alignment: .trailing) { Rectangle().frame(width: width * (1 - split)) }
            Image(decorative: preview.before, scale: 1).resizable()
                .interpolation(preview.detail == nil ? .high : .none)
                .frame(width: width, height: height)
                .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
            ZStack {
                if isGeneratingAI { AIShimmer().transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isGeneratingAI)
            .allowsHitTesting(false).accessibilityHidden(true)
            if preview.detail == nil, pickFocus != nil,
               let crop = try? DetailGeometry(imageSize: preview.input, focus: focus, scale: CGSize(width: 1, height: 1)) {
                Rectangle().strokeBorder(.white, lineWidth: 1)
                    .shadow(color: .black, radius: 1)
                    .frame(width: crop.rect.width / CGFloat(preview.input.width) * width,
                           height: crop.rect.height / CGFloat(preview.input.height) * height)
                    .offset(x: crop.rect.minX / CGFloat(preview.input.width) * width,
                            y: crop.rect.midY / CGFloat(preview.input.height) * height - height / 2)
                    .opacity(hovering || showsFocus ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering || showsFocus)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            Group {
                Rectangle().fill(.white).frame(width: 1, height: height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: width * split - 0.5)
                    .accessibilityHidden(true)
                Image(systemName: "chevron.left.chevron.right").font(.callout.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white).darkGlassSurface(Circle(), interactive: true)
                    .scaleEffect(draggingSplit == true ? 1.08 : 1)
                    .animation(reduceMotion ? nil : .spring, value: draggingSplit)
                    .offset(x: min(width - 38, max(0, width * split - 19)))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hovering = true
            case .ended: hovering = false
            }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if draggingSplit == nil {
                draggingSplit = preview.detail != nil || pickFocus == nil ||
                    abs(value.startLocation.x - width * split) <= 20
            }
            if draggingSplit == true { split = min(1, max(0, value.location.x / width)) }
            else { pickFocus?(CGPoint(x: value.location.x / width, y: value.location.y / height)) }
        }.onEnded { _ in draggingSplit = nil })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(split * 100)) percent original")
        .accessibilityAdjustableAction { direction in
            split = min(1, max(0, split + (direction == .increment ? 0.05 : -0.05)))
        }
        .overlay(alignment: .topLeading) {
            if split > 0 {
                comparisonLabel("Original") { split = 1 }.padding(14)
            }
        }
        .overlay(alignment: .topTrailing) {
            if split < 1 {
                comparisonLabel(isAI ? "AI Restore" : "Upscaled",
                                symbol: isAI ? "sparkles" : nil) { split = 0 }.padding(14)
            }
        }
    }

    private var isAI: Bool { preview.method == OptionalEngine.fluxKleinRestore.name }
    private func comparisonLabel(_ title: String, symbol: String? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(.white).darkGlassSurface(Capsule())
        }.buttonStyle(.plain).help("Show \(title.lowercased())")
    }
}

private struct AIShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    GeometryReader { geometry in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        LinearGradient(colors: [.clear, .white.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.35, height: geometry.size.height * 2)
                            .rotationEffect(.degrees(20))
                            .position(x: geometry.size.width * (phase * 2 - 0.5), y: geometry.size.height / 2)
                            .blendMode(.plusLighter)
                    }
                }
            }
        }
    }
}
