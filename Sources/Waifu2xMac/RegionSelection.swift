import SwiftUI

// Normalized top-left coordinates for reference cropping.
struct RegionSelection: View {
    let region: CGRect?
    var label = "Crop"
    var editable = true
    let commit: (CGRect) -> Void
    @State private var draft: CGRect?
    @State private var starting: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = draft ?? region
            ZStack(alignment: .topLeading) {
                if editable {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                            draft = rectangle(value.startLocation, value.location, size: size)
                        }.onEnded { _ in finish() })
                }
                if let rect {
                    let box = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                     width: rect.width * size.width, height: rect.height * size.height)
                    Rectangle().fill(.white.opacity(0.05))
                        .overlay { Rectangle().strokeBorder(.white, lineWidth: 1) }
                        .overlay(alignment: .topLeading) {
                            Text(label).font(.caption2.weight(.semibold)).padding(3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.primary)
                        }
                        .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if starting == nil { starting = rect }
                            guard let start = starting else { return }
                            draft = CGRect(x: min(1 - start.width, max(0, start.minX + value.translation.width / size.width)),
                                y: min(1 - start.height, max(0, start.minY + value.translation.height / size.height)),
                                width: start.width, height: start.height)
                        }.onEnded { _ in finish() })
                    if editable {
                        ForEach(0..<4) { corner in
                            let x = corner % 2 == 0 ? box.minX : box.maxX
                            let y = corner < 2 ? box.minY : box.maxY
                            Circle().fill(.white).frame(width: 10, height: 10)
                                .position(x: x, y: y)
                                .gesture(DragGesture(coordinateSpace: .named("region")).onChanged { value in
                                    if starting == nil { starting = rect }
                                    guard let start = starting else { return }
                                    let anchor = CGPoint(x: (corner % 2 == 0 ? start.maxX : start.minX) * size.width,
                                        y: (corner < 2 ? start.maxY : start.minY) * size.height)
                                    draft = rectangle(anchor, value.location, size: size)
                                }.onEnded { _ in finish() })
                        }
                    }
                }
            }
            .coordinateSpace(name: "region")
        }
        .allowsHitTesting(editable)
        .focusable(editable)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard editable else { return .ignored }
            let rect = draft ?? region ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
            let dx: CGFloat = press.key == .leftArrow ? -0.01 : press.key == .rightArrow ? 0.01 : 0
            let dy: CGFloat = press.key == .upArrow ? -0.01 : press.key == .downArrow ? 0.01 : 0
            if press.modifiers.contains(.shift) {
                draft = CGRect(x: rect.minX, y: rect.minY, width: min(1 - rect.minX, max(0.01, rect.width + dx)),
                    height: min(1 - rect.minY, max(0.01, rect.height + dy)))
            } else {
                draft = CGRect(x: min(1 - rect.width, max(0, rect.minX + dx)),
                    y: min(1 - rect.height, max(0, rect.minY + dy)), width: rect.width, height: rect.height)
            }
            finish()
            return .handled
        }
        .onChange(of: region) { draft = region }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) rectangle")
        .accessibilityHint("Drag to draw, move or resize. Arrow keys move; Shift and arrow keys resize.")
        .accessibilityAdjustableAction { direction in
            let rect = draft ?? region ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
            let delta: CGFloat = direction == .increment ? -0.02 : 0.02
            draft = rect.insetBy(dx: delta, dy: delta).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            finish()
        }
    }

    private func rectangle(_ a: CGPoint, _ b: CGPoint, size: CGSize) -> CGRect {
        let a = CGPoint(x: min(1, max(0, a.x / size.width)), y: min(1, max(0, a.y / size.height)))
        let b = CGPoint(x: min(1, max(0, b.x / size.width)), y: min(1, max(0, b.y / size.height)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func finish() {
        starting = nil
        if let draft, draft.width > 0.005, draft.height > 0.005 { commit(draft) }
        else { draft = region }
    }
}
