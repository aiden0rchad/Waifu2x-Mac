import SwiftUI

private actor AmbientCache {
    static let shared = AmbientCache()
    private var images: [(source: CGImage, thumbnail: CGImage)] = []

    func thumbnail(for image: CGImage) -> CGImage? {
        if let cached = images.first(where: { $0.source === image }) { return cached.thumbnail }
        let scale = min(1, 48 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        images.append((image, thumbnail))
        if images.count > 8 { images.removeFirst() }
        return thumbnail
    }
}

struct AmbientBackdrop: View {
    let image: CGImage?
    var showsIdleLight = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if scheme == .dark { Color.black.opacity(0.65) }
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 60).saturation(1.3)
                        .opacity(scheme == .dark ? 0.55 : 0.35)
                        .id(ObjectIdentifier(thumbnail)).transition(.opacity)
                } else if image == nil && showsIdleLight {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                        let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * .pi / 10
                        Circle().fill(Color.accentColor.opacity(0.25))
                            .frame(width: 560, height: 560).blur(radius: 140)
                            .offset(x: cos(phase) * 100, y: sin(phase) * 60)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                // A blurred aperture supplies the radial vignette without another gradient.
                Canvas { context, size in
                    var aperture = Path(CGRect(origin: .zero, size: size).insetBy(dx: -200, dy: -200))
                    aperture.addEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06,
                                                                                     dy: size.height * 0.06))
                    context.addFilter(.blur(radius: 80))
                    context.fill(aperture, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                }
            }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 80)
            }
            .clipped()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: thumbnail.map(ObjectIdentifier.init))
        .task(id: image.map(ObjectIdentifier.init)) {
            guard let image else { return } // Keep the previous tint during preview loading.
            let result = await AmbientCache.shared.thumbnail(for: image)
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
