import AVFoundation
import CoreImage
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public enum MediaKind: String, Codable, Sendable {
    case image = "Image", gif = "GIF", video = "Video"

    public init?(url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        if type == .gif { self = .gif }
        else if type?.conforms(to: .movie) == true { self = .video }
        else if type?.conforms(to: .image) == true { self = .image }
        else { return nil }
    }

}

public struct Dimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var label: String { "\(width) × \(height)" }
}

public enum OutputSize: String, CaseIterable, Codable, Sendable {
    case double = "2×", triple = "3×", quadruple = "4×"
    case hd = "1080p", qhd = "1440p", uhd = "4K", portrait = "Portrait", custom = "Custom"

    public var isScale: Bool { self == .double || self == .triple || self == .quadruple }

    func bounds(customWidth: Int, customHeight: Int) -> Dimensions? {
        switch self {
        case .hd: Dimensions(width: 1920, height: 1080)
        case .qhd: Dimensions(width: 2560, height: 1440)
        case .uhd: Dimensions(width: 3840, height: 2160)
        case .portrait: Dimensions(width: 1080, height: 1920)
        case .custom: Dimensions(width: customWidth, height: customHeight)
        default: nil
        }
    }


}

public enum Preset: String, CaseIterable, Codable, Sendable {
    case anime4k = "Anime4K", anime4kRestore = "Anime4K Restore"
    case waifu2xArt = "Waifu2x Art", waifu2xPhoto = "Waifu2x Photo"
    case realCUGAN = "Real-CUGAN", realESRGAN = "Real-ESRGAN"
    case realSR = "RealSR", realSRJPEG = "RealSR JPEG"
    case fast = "Fast", illustration = "Illustration", photo = "Photo", enhance = "Apple ML"

    public static var available: [Self] {
        allCases.filter { $0 != .enhance || SuperResolution.isAvailable }
    }

    public var tagline: String {
        switch self {
        case .realCUGAN: "Best all-round for anime and comics"
        case .realESRGAN: "Crisp textures for illustration and animation"
        case .anime4k: "Fast, clean outlines for anime"
        case .anime4kRestore: "Repairs soft or broken outlines"
        case .waifu2xArt: "Classic upscaler for illustrations"
        case .illustration: "Instant resize with sharper edges"
        case .realSR: "Most detailed photo upscaling"
        case .realSRJPEG: "Cleans up blocky, compressed photos"
        case .waifu2xPhoto: "Gentle detail for photos"
        case .photo: "Instant resize with light smoothing"
        case .fast: "Instant resize, no AI"
        case .enhance: "Apple's built-in super resolution"
        }
    }

    public var detail: String {
        switch self {
        case .anime4k: "ACNet neural scaling for anime and line art."
        case .anime4kRestore: "Larger ACNet model trained to restore outlines and mildly denoise."
        case .waifu2xArt: "Waifu2x RGB model trained for illustrations and anime."
        case .waifu2xPhoto: "Waifu2x neural scaling for camera images and textures."
        case .realCUGAN: "2× restoration for anime, comics and thin lines."
        case .realESRGAN: "4× AnimeVideo v3 restores crisp textures in illustrations and animation."
        case .realSR: "4× DF2K model for photos and live-action frames."
        case .realSRJPEG: "4× DF2K JPEG model for blocky, heavily compressed photos."
        case .fast: "MetalFX spatial scaling where available."
        case .illustration: "Lanczos scaling with extra edge contrast."
        case .photo: "Lanczos scaling with light noise reduction."
        case .enhance: "Apple ML super resolution for supported opaque inputs. Other inputs use Lanczos."
        }
    }
}

public enum VideoEngine: String, CaseIterable, Codable, Sendable {
    case spatial = "Use image engine", safmn = "SAFMN++ Light", nano = "NanoVSR", nanoDetail = "NanoVSR Detail"

    public var isTemporal: Bool { self == .nano || self == .nanoDetail }

    public var tagline: String {
        switch self {
        case .spatial: "Runs the image engine on every frame"
        case .safmn: "Fast AI upscaling for compressed video"
        case .nano: "Steadier detail from neighbouring frames"
        case .nanoDetail: "Finest detail for small, low-resolution clips"
        }
    }

    public var detail: String {
        switch self {
        case .spatial: "Applies the selected image engine to each frame."
        case .safmn: "Tiled 4× AI upscaling for compressed video, one frame at a time."
        case .nano: "Small temporal model that restores detail using neighboring frames."
        case .nanoDetail: "Larger temporal model for fine detail and steadier textures in low-resolution clips."
        }
    }

    public var inputNote: String {
        switch self {
        case .spatial: "Choose an image engine for stills and per-frame video."
        case .safmn: "Supports inputs up to 2,048 pixels per side and 2.1 megapixels."
        case .nano, .nanoDetail: "Up to 640 pixels on the longer side and 307,200 pixels per frame."
        }
    }

    func validate(_ size: Dimensions) throws {
        switch self {
        case .spatial: break
        case .safmn:
            guard max(size.width, size.height) <= 2048,
                  size.width * size.height <= 2_100_000 else { throw UpscaleError.safmnInputTooLarge }
        case .nano, .nanoDetail:
            guard (8...640).contains(size.width), (8...640).contains(size.height),
                  size.width * size.height <= 307_200 else { throw UpscaleError.videoModelSize }
        }
    }
}

public enum MotionEngine: String, CaseIterable, Codable, Sendable {
    case off = "Off", rife = "RIFE 4.6", apple = "Apple VideoToolbox"
}

public struct UpscaleOptions: Equatable, Codable, Sendable {
    public var size: OutputSize
    public var preset: Preset
    public var optionalEngineID: String?
    private var restoreOverride: RestoreSettings?
    public var restore: RestoreSettings {
        get { restoreOverride ?? RestoreSettings() }
        set { restoreOverride = newValue }
    }
    public var usesAI: Bool { optionalEngineID == OptionalEngine.fluxKleinRestore.id }
    public var engineName: String { usesAI ? OptionalEngine.fluxKleinRestore.name : preset.rawValue }
    public var smootherMotion: Bool
    private var motionEngineOverride: MotionEngine?
    public var motionEngine: MotionEngine {
        get { motionEngineOverride ?? (smootherMotion ? .apple : .off) }
        set {
            motionEngineOverride = newValue == .rife ? .rife : nil
            smootherMotion = newValue == .apple
        }
    }
    // Preserve the setting in presets saved before video engine selection was added.
    private var temporalVideo: Bool?
    private var videoEngineOverride: VideoEngine?

    public var videoEngine: VideoEngine {
        get { videoEngineOverride ?? (temporalVideo == true ? .nano : .spatial) }
        set { videoEngineOverride = newValue; temporalVideo = nil }
    }
    public var customWidth = 1920
    public var customHeight = 1080
    public var fitInside = true
    public var noiseReduction: DetailLevel = .automatic
    public var edgeDetail: DetailLevel = .automatic
    public var export = ExportSettings()

    public init(size: OutputSize = .double, preset: Preset = .illustration, smootherMotion: Bool = false) {
        self.size = size
        self.preset = preset
        self.smootherMotion = smootherMotion
    }

    public var usesTemporalVideo: Bool { videoEngine.isTemporal }
    public var interpolatesMotion: Bool { motionEngine != .off && !usesTemporalVideo }

    public var sizeLabel: String {
        size == .custom ? "\(customWidth) × \(customHeight)" : size.rawValue
    }

    public func dimensions(for input: Dimensions, video: Bool = false) throws -> Dimensions {
        guard input.width > 0, input.height > 0 else { throw UpscaleError.unreadable }
        let width = Double(input.width)
        let height = Double(input.height)
        let output: (Double, Double)
        if let bounds = size.bounds(customWidth: customWidth, customHeight: customHeight) {
            guard bounds.width > 0, bounds.height > 0 else { throw UpscaleError.invalidSize }
            let w = Double(bounds.width)
            let h = Double(bounds.height)
            let factor = min(w / width, h / height)
            output = fitInside ? (width * factor, height * factor) : (w, h)
        } else {
            let factor: Double = size == .double ? 2 : size == .triple ? 3 : 4
            output = (width * factor, height * factor)
        }
        let w = max(1, output.0.rounded())
        let h = max(1, output.1.rounded())
        let sideLimit: Double = video ? 4096 : 16384
        guard w <= sideLimit, h <= sideLimit, w * h <= 50_000_000 else { throw UpscaleError.tooLarge }
        return video ? Dimensions(width: (Int(w) + 1) & ~1, height: (Int(h) + 1) & ~1)
                     : Dimensions(width: Int(w), height: Int(h))
    }

    public static var canInterpolateVideo: Bool {
        if #available(macOS 26, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        return false
    }
}

public struct MediaPreview: @unchecked Sendable {
    public let before: CGImage
    public let after: CGImage
    public let input: Dimensions
    public let output: Dimensions
    public let method: String
    public let detail: DetailGeometry?
    public let restoreOutcome: RestoreOutcome?

    init(before: CGImage, after: CGImage, input: Dimensions, output: Dimensions, method: String,
         detail: DetailGeometry? = nil, restoreOutcome: RestoreOutcome? = nil) {
        self.before = before
        self.after = after
        self.input = input
        self.output = output
        self.method = method
        self.detail = detail
        self.restoreOutcome = restoreOutcome
    }

    public var representation: String {
        if let detail {
            return "Detail at actual export pixels · \(Int(detail.rect.width)) × \(Int(detail.rect.height)) source → \(detail.output.label)"
        }
        return "Whole image · fit preview · Export: \(input.label) → \(output.label)"
    }
}

enum UpscaleError: LocalizedError {
    case unsupported, unreadable, tooLarge, neuralInputTooLarge, videoModelSize, safmnInputTooLarge, render, encode, noVideo, motionUnavailable, rifeInputTooLarge, encoderStalled, invalidSize

    var errorDescription: String? {
        switch self {
        case .unsupported: "This file type isn’t supported."
        case .unreadable: "The input couldn’t be decoded."
        case .tooLarge: "The requested output is too large. Choose a smaller scale or a fit preset."
        case .neuralInputTooLarge: "The model’s native upscale would exceed 50 megapixels. Choose another engine or resize the source first."
        case .safmnInputTooLarge: "SAFMN++ Light supports inputs up to 2,048 pixels per side and 2.1 megapixels."
        case .videoModelSize: "NanoVSR is for low-resolution video up to 640 pixels per side and 307,200 pixels total. Use SAFMN++ Light or an image engine for larger clips."
        case .render: "The frame couldn’t be rendered."
        case .encode: "The output couldn’t be encoded."
        case .noVideo: "The file doesn’t contain a readable video track."
        case .motionUnavailable: "Smoother motion is unavailable for this video or Mac. Turn it off and retry."
        case .rifeInputTooLarge: "RIFE supports inputs up to 1,920 pixels per side and 2,073,600 pixels per frame. Choose another motion setting for larger sources."
        case .invalidSize: "Enter a width and height greater than zero."
        case .encoderStalled: "The video encoder stopped responding. Try a smaller output size."
        }
    }
}

public struct Upscaler: Sendable {
    typealias AIRestorer = @Sendable (CIImage, Dimensions, UpscaleOptions, [ReferenceImage], FrameRenderer,
        @escaping @Sendable (Double) -> Void) async throws -> RestoreResult
    private let restore: AIRestorer
    private let aiCache = RestorePreviewCache()

    public init() {
        restore = { image, size, options, references, renderer, progress in
            try await DiffusionRestore().render(image, to: size, options: options,
                references: references, renderer: renderer, progress: progress)
        }
    }

    init(restore: @escaping AIRestorer) { self.restore = restore }

    public func hasAIPreview(_ source: URL, options: UpscaleOptions, references: [ReferenceImage]) async -> Bool {
        await aiCache.image(for: RestorePreviewKey(source: source, options: options, references: references)) != nil
    }

    public func clearAIPreview() async { await aiCache.clear() }

    public func preview(_ source: URL, options: UpscaleOptions, focus: CGPoint? = nil,
                        generateAI: Bool = false, references: [ReferenceImage] = [],
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> MediaPreview {
        guard let kind = MediaKind(url: source) else { throw UpscaleError.unsupported }
        let image: CIImage
        let input: Dimensions
        let opaque: Bool
        let videoEngine = kind == .video ? options.videoEngine : .spatial
        if kind == .video {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw UpscaleError.noVideo
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized
            input = Dimensions(width: Int(oriented.width.rounded()), height: Int(oriented.height.rounded()))
            try videoEngine.validate(input)
            if videoEngine.isTemporal {
                return try temporalPreview(asset: asset, track: track, transform: transform, input: input, options: options)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let previewLimit = options.preset == .enhance ? 960 : 720
            if focus == nil { generator.maximumSize = CGSize(width: previewLimit, height: previewLimit) }
            let frame = try await generator.image(at: .zero).image
            image = CIImage(cgImage: frame)
            opaque = true
        } else {
            let frame = try still(source)
            input = frame.image.dimensions
            opaque = frame.opaque
            image = frame.image
        }

        try Task.checkCancellation()
        let output = try options.dimensions(for: input, video: kind == .video)
        let renderer = FrameRenderer()
        if options.usesAI, kind != .video {
            var baseOptions = options
            baseOptions.optionalEngineID = nil
            baseOptions.preset = options.restore.base(for: options.preset)
            if !generateAI { return try await preview(source, options: baseOptions, focus: focus) }
            let detail = try focus.map { try DetailGeometry(imageSize: input, focus: $0,
                scale: CGSize(width: Double(output.width) / Double(input.width), height: Double(output.height) / Double(input.height))) }
            let key = RestorePreviewKey(source: source, options: options, references: references)
            let full: CGImage
            let outcome: RestoreOutcome
            if let cached = await aiCache.image(for: key) { full = cached.image; outcome = cached.outcome }
            else {
                let rendered = try await restore(image, output, options, references, renderer, progress)
                try Task.checkCancellation()
                full = try renderer.image(rendered.image)
                outcome = rendered.outcome
                await aiCache.store(full, outcome: outcome, for: key)
            }
            let before: CIImage
            let after: CIImage
            if let detail {
                before = renderer.lanczos(image.topLeftCrop(detail.rect),
                    to: CGRect(x: 0, y: 0, width: detail.output.width, height: detail.output.height))
                let x = (detail.rect.minX * CGFloat(output.width) / CGFloat(input.width)).rounded()
                let y = (detail.rect.minY * CGFloat(output.height) / CGFloat(input.height)).rounded()
                let rect = CGRect(x: min(CGFloat(output.width - detail.output.width), x),
                    y: min(CGFloat(output.height - detail.output.height), y),
                    width: CGFloat(detail.output.width), height: CGFloat(detail.output.height))
                after = CIImage(cgImage: full).topLeftCrop(rect)
            } else {
                before = renderer.thumbnail(image, maxSide: 720)
                after = renderer.thumbnail(CIImage(cgImage: full), maxSide: 1200)
            }
            return try MediaPreview(before: renderer.image(before), after: renderer.image(after),
                input: input, output: output, method: OptionalEngine.fluxKleinRestore.name, detail: detail, restoreOutcome: outcome)
        }
        let videoModel: NeuralScaler.Kind? = videoEngine == .safmn ? .safmn : nil
        let neuralKind = videoModel ?? NeuralScaler.model(for: options.preset, denoise: options.noiseReduction)
        let usesModel = neuralKind != nil
        let previewOpaque = opaque || (kind == .gif && usesModel && renderer.isOpaque(image))
        // Use export dimensions for the plan, including its intermediate 50 MP cap.
        let neuralPassPlan = try previewOpaque ? neuralKind.map {
            try FrameRenderer.neuralPlan(from: input, to: output, kind: $0)
        } : nil
        if let focus {
            let detail = try DetailGeometry(imageSize: input, focus: focus,
                                            scale: CGSize(width: Double(output.width) / Double(input.width),
                                                          height: Double(output.height) / Double(input.height)))
            let rect = CGRect(x: detail.rect.minX, y: CGFloat(input.height) - detail.rect.maxY,
                              width: detail.rect.width, height: detail.rect.height)
            let crop = image.normalized.cropped(to: rect).normalized
            let scaled = try await renderer.scale(crop, to: detail.output, options: options,
                                                   opaque: previewOpaque, allowNeural: true, videoModel: videoModel,
                                                   neuralPassPlan: neuralPassPlan)
            try Task.checkCancellation()
            let before = renderer.lanczos(crop, to: CGRect(x: 0, y: 0, width: detail.output.width, height: detail.output.height))
            return try MediaPreview(before: renderer.image(before), after: renderer.image(scaled),
                                    input: input, output: output, method: renderer.method, detail: detail)
        }
        let beforeFrame = renderer.thumbnail(image, maxSide: 720)
        let factor = min(1, 1200 / Double(max(output.width, output.height)))
        let previewSize = Dimensions(width: max(1, Int(Double(output.width) * factor)),
                                     height: max(1, Int(Double(output.height) * factor)))
        let afterFrame: CIImage
        if videoModel == nil, options.preset == .enhance, max(image.extent.width, image.extent.height) <= 960,
           image.dimensions == input, max(output.width, output.height) <= 1920 {
            let rendered = try await renderer.scale(image, to: output, options: options, opaque: opaque)
            afterFrame = renderer.thumbnail(rendered, maxSide: 1200)
        } else {
            let sample = usesModel ? renderer.thumbnail(image, maxSide: 480) : beforeFrame
            // Preserve the export's scale ratio (and neural pass count) before fitting
            // the result to the preview. Its display size must not select the passes.
            let renderSize = usesModel ? Dimensions(
                width: max(1, Int((sample.extent.width * Double(output.width) / Double(input.width)).rounded())),
                height: max(1, Int((sample.extent.height * Double(output.height) / Double(input.height)).rounded()))) : previewSize
            let rendered = try await renderer.scale(sample, to: renderSize, options: options,
                                                  opaque: previewOpaque, allowML: false,
                                                  allowNeural: output.width > input.width || output.height > input.height,
                                                  videoModel: videoModel, neuralPassPlan: neuralPassPlan)
            afterFrame = rendered.dimensions == previewSize ? rendered : renderer.lanczos(rendered,
                to: CGRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height))
        }
        return try MediaPreview(before: renderer.image(beforeFrame), after: renderer.image(afterFrame),
                                input: input, output: output, method: renderer.method)
    }

    public func export(_ source: URL, to folder: URL, options: UpscaleOptions, references: [ReferenceImage] = [],
                       restoreSummary: @escaping @Sendable (RestoreSummary) async -> Void = { _ in },
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let kind = MediaKind(url: source) else { throw UpscaleError.unsupported }
        try Task.checkCancellation()
        let staging = folder.appendingPathComponent(".waifu2x-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("output")
            .appendingPathExtension(options.export.outputExtension(for: kind))

        let renderer = FrameRenderer()
        var summary = RestoreSummary()
        switch kind {
        case .image:
            let frame = try still(source)
            let dimensions = try options.dimensions(for: frame.image.dimensions)
            let scaled: CIImage
            if options.usesAI {
                let result = try await restore(frame.image, dimensions, options, references, renderer, progress)
                scaled = result.image
                summary.record(result.outcome)
            } else {
                scaled = try await renderer.scale(frame.image, to: dimensions, options: options, opaque: frame.opaque)
            }
            let format = options.export.imageFormat
            let flattened = format == .jpeg
                ? scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
                : scaled
            let result = try renderer.image(flattened)
            guard let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL, format.type.identifier as CFString, 1, nil
            ) else { throw UpscaleError.encode }
            let properties = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.export.jpegQuality))]
            CGImageDestinationAddImage(destination, result, format == .jpeg ? properties as CFDictionary : nil)
            guard CGImageDestinationFinalize(destination) else { throw UpscaleError.encode }
        case .gif:
            summary = try await exportGIF(source, to: temporary, options: options, references: references, renderer: renderer, progress: progress)
        case .video:
            try await exportVideo(source, to: temporary, options: options, renderer: renderer, progress: progress)
        }

        try Task.checkCancellation()
        let name = (options.export.outputName(for: source, kind: kind) as NSString).deletingPathExtension
        // Staging stays on the destination volume, so the exclusive rename publishes a complete file.
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " \(index)"
            let output = folder.appendingPathComponent(name + suffix).appendingPathExtension(options.export.outputExtension(for: kind))
            if renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) == 0 {
                await restoreSummary(summary)
                progress(1)
                return output
            }
            let code = errno
            guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func still(_ url: URL) throws -> (image: CIImage, opaque: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw UpscaleError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        return (CIImage(cgImage: image).oriented(forExifOrientation: orientation).normalized, image.isOpaque)
    }

    private func exportGIF(_ source: URL, to output: URL, options: UpscaleOptions,
                           references: [ReferenceImage], renderer: FrameRenderer, progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreSummary {
        var summary = RestoreSummary()
        guard let animation = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(animation) > 0 else { throw UpscaleError.unreadable }
        let count = CGImageSourceGetCount(animation)
        let usesRIFE = !options.usesAI && options.motionEngine == .rife && count > 1
        let checksOpacity = !options.usesAI && (usesRIFE || NeuralScaler.model(for: options.preset) != nil)
        let container = CGImageSourceCopyProperties(animation, nil) as? [CFString: Any]
        let gif = container?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        func decode(_ index: Int) throws -> (image: CIImage, opaque: Bool, pixels: CGImage) {
            try autoreleasepool {
                guard let frame = CGImageSourceCreateImageAtIndex(animation, index, nil) else {
                    throw UpscaleError.unreadable
                }
                let image = CIImage(cgImage: frame)
                return (image, frame.isOpaque || (checksOpacity && renderer.isOpaque(image)), frame)
            }
        }
        // Retain metadata rather than decoded frames for the whole animation.
        var frames: [(size: Dimensions, opaque: Bool, delay: Double)] = []
        var hashes: [SHA256.Digest] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let frame = try decode(index)
            let properties = CGImageSourceCopyPropertiesAtIndex(animation, index, nil) as? [CFString: Any]
            let timing = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = max(0.01, (timing?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ??
                                  timing?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1) / options.export.gifSpeed.rawValue)
            frames.append((frame.image.dimensions, frame.opaque, delay))
            if options.usesAI {
                hashes.append(try autoreleasepool { try Self.gifFrameHash(frame.pixels) })
            }
        }
        let interpolates = Self.gifMidpoints(frames, enabled: usesRIFE)
        let outputCount = count + interpolates.filter { $0 }.count
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, outputCount, nil
        ) else { throw UpscaleError.encode }
        if let loop = options.export.loopGIF ? 0 : gif?[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]
            ] as CFDictionary)
        }
        if options.usesAI {
            let plan = Self.gifRestorePlan(hashes)
            var restored: [CGImage?] = Array(repeating: nil, count: plan.unique.count)
            var outcomes = [RestoreOutcome](repeating: .restored, count: plan.unique.count)
            var completed = 0
            for index in 0..<count {
                try Task.checkCancellation()
                let slot = plan.mapping[index]
                if restored[slot] == nil {
                    let frame = try decode(index)
                    let size = try options.dimensions(for: frame.image.dimensions)
                    let completedBefore = completed
                    let uniqueCount = plan.unique.count
                    let result = try await restore(frame.image, size, options, references, renderer, { value in
                            progress((Double(completedBefore) + value) / Double(uniqueCount))
                        })
                    try Task.checkCancellation()
                    restored[slot] = try autoreleasepool { try renderer.image(result.image) }
                    outcomes[slot] = result.outcome
                    completed += 1
                    progress(Double(completed) / Double(plan.unique.count))
                }
                guard let image = restored[slot] else { throw UpscaleError.render }
                summary.record(outcomes[slot])
                autoreleasepool {
                    CGImageDestinationAddImage(destination, image, [
                        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frames[index].delay]
                    ] as CFDictionary)
                }
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else { throw UpscaleError.encode }
            return summary
        }
        func append(_ image: CIImage, opaque: Bool, delay: Double) async throws {
            let size = try options.dimensions(for: image.dimensions)
            let scaled = try await renderer.scale(image, to: size, options: options, opaque: opaque)
            try autoreleasepool {
                CGImageDestinationAddImage(destination, try renderer.image(scaled), [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
                ] as CFDictionary)
            }
        }
        var motion: RIFEInterpolation?
        var next: (image: CIImage, opaque: Bool, pixels: CGImage)?
        for index in 0..<count {
            try Task.checkCancellation()
            let (image, opaque, _) = try next ?? decode(index)
            let delay = frames[index].delay
            next = interpolates[index] ? try decode(index + 1) : nil
            if let next {
                if motion == nil { motion = try RIFEInterpolation() }
                guard let motion else { throw UpscaleError.render }
                let middle = try motion.midpoint(image, next.image, renderer: renderer)
                let firstDelay = (delay * 50).rounded(.down) / 100
                try await append(image, opaque: true, delay: firstDelay)
                try await append(middle, opaque: true, delay: delay - firstDelay)
            } else {
                try await append(image, opaque: opaque, delay: delay)
            }
            progress(Double(index + 1) / Double(count + 1))
        }
        guard CGImageDestinationFinalize(destination) else { throw UpscaleError.encode }
        return summary
    }

    static func gifMidpoints(_ frames: [(size: Dimensions, opaque: Bool, delay: Double)], enabled: Bool) -> [Bool] {
        frames.indices.map { index in
            enabled && index + 1 < frames.count && frames[index].delay >= 0.04 && frames[index].opaque &&
                frames[index + 1].opaque && frames[index].size == frames[index + 1].size
        }
    }

    static func gifRestorePlan<Hash: Hashable>(_ hashes: [Hash]) -> (unique: [Int], mapping: [Int]) {
        var slots: [Hash: Int] = [:]
        var unique: [Int] = [], mapping: [Int] = []
        for (index, hash) in hashes.enumerated() {
            if slots[hash] == nil { slots[hash] = unique.count; unique.append(index) }
            mapping.append(slots[hash]!)
        }
        return (unique, mapping)
    }

    static func gifFrameHash(_ image: CGImage) throws -> SHA256.Digest {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw UpscaleError.render
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var hash = SHA256()
        hash.update(data: Data("\(width)x\(height):".utf8))
        hash.update(data: Data(pixels))
        return hash.finalize()
    }
}

extension CIImage {
    var dimensions: Dimensions {
        Dimensions(width: Int(extent.width.rounded()), height: Int(extent.height.rounded()))
    }

    var normalized: CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

private extension CGImage {
    var isOpaque: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
    }
}


private struct RestorePreviewKey: Equatable, Sendable {
    let source: URL
    let options: UpscaleOptions
    let references: [ReferenceImage]
}

// Keep only one export-sized result; focus and display mode deliberately do not enter the key.
private actor RestorePreviewCache {
    private var key: RestorePreviewKey?
    private var value: (image: CGImage, outcome: RestoreOutcome)?
    func image(for key: RestorePreviewKey) -> (image: CGImage, outcome: RestoreOutcome)? { self.key == key ? value : nil }
    func store(_ image: CGImage, outcome: RestoreOutcome, for key: RestorePreviewKey) {
        self.key = key; value = (image, outcome)
    }
    func clear() { key = nil; value = nil }
}
