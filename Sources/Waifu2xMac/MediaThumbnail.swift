import QuickLookThumbnailing
import ImageIO
import SwiftUI
import UpscaleCore
import Observation

struct MediaThumbnail: View {
    let url: URL
    var size = CGSize(width: 56, height: 42)
    var cornerRadius: CGFloat = 7
    var contentMode: ContentMode = .fill
    var blurredFill = false
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if contentMode == .fit { Color.black.opacity(0.25) }
            else { Rectangle().fill(.quaternary) }
            if let image {
                if blurredFill {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                        .blur(radius: 18).brightness(-0.25)
                }
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            }
            else { Image(systemName: "doc").foregroundStyle(.secondary) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            let pixels = max(size.width, size.height, 64) * displayScale
            if let still = await Task.detached(operation: { Self.imageIOThumbnail(url, pixels: pixels) }).value {
                if !Task.isCancelled { image = NSImage(cgImage: still, size: .zero) }
                return
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels),
                                                       scale: 1, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
               !Task.isCancelled { image = thumbnail.nsImage }
        }
    }

    // ImageIO first: QuickLook can stall indefinitely for images in this app. QuickLook remains for video.
    nonisolated fileprivate static func imageIOThumbnail(_ url: URL, pixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
        return cgImage
    }
}

@MainActor @Observable final class MediaMetadata {
    static let shared = MediaMetadata()
    private(set) var sizes: [URL: Dimensions] = [:]
    private(set) var byteCounts: [URL: Int] = [:]
    private(set) var backdrops: [URL: CGImage] = [:]
    private var requested: Set<URL> = []
    private var backdropRequests: Set<URL> = []

    func load(_ job: Job) async {
        guard requested.insert(job.id).inserted else { return }
        let result = await Task.detached(priority: .utility) {
            await Job.ResultDetails.read(job.source, kind: job.kind, duration: 0)
        }.value
        sizes[job.id] = result.dimensions
        byteCounts[job.id] = result.byteCount
    }

    func loadBackdrop(_ url: URL) async {
        guard MediaKind(url: url) != .video, backdropRequests.insert(url).inserted else { return }
        backdrops[url] = await Task.detached(priority: .utility) {
            MediaThumbnail.imageIOThumbnail(url, pixels: 256)
        }.value
    }
}

struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.frame(width: size, height: size)
            .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}
