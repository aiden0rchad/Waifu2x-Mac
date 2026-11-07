import CoreImage
import CoreML

final class NeuralScaler {
    enum Kind: String, CaseIterable {
        case anime = "Anime4K", restore = "Anime4KRestore", art = "Waifu2xArt", photo = "Waifu2xPhoto"
        case safmn = "SAFMNLight"
        case cugan = "CUGAN", cuganLow = "CUGANLow", cuganMedium = "CUGANMedium", cuganHigh = "CUGANHigh"
        case esrgan = "RealESRGAN", realSR = "RealSR", realSRJPEG = "RealSRJPEG"

        var factor: Int {
            switch self {
            case .safmn, .esrgan, .realSR, .realSRJPEG: 4
            default: 2
            }
        }

        var tile: Int {
            switch self {
            case .cugan, .cuganLow, .cuganMedium, .cuganHigh: 128
            case .esrgan: 160
            case .realSR, .realSRJPEG: 80
            default: 192
            }
        }

        var fileExtension: String {
            switch self {
            case .anime, .restore, .art, .photo: "mlmodel"
            default: "mlpackage"
            }
        }

        var halo: Int {
            switch self {
            case .anime: 6
            case .restore: 20
            case .art, .photo: 7
            case .safmn: 64
            case .cugan, .cuganLow, .cuganMedium, .cuganHigh: 24
            case .esrgan: 18
            case .realSR, .realSRJPEG: 32
            }
        }

        var continuation: Kind {
            switch self {
            case .cuganLow, .cuganMedium, .cuganHigh: .cugan
            case .restore: .anime
            default: self
            }
        }

        var alignment: Int {
            switch self {
            case .cugan, .cuganLow, .cuganMedium, .cuganHigh: 2
            default: 1
            }
        }

        func accepts(_ size: Dimensions) -> Bool {
            size.width > 0 && size.height > 0 && size.width <= 50_000_000 / (factor * factor) / size.height
        }
    }

    static func model(for preset: Preset, denoise: DetailLevel = .automatic) -> Kind? {
        switch preset {
        case .anime4k: .anime
        case .anime4kRestore: .restore
        case .waifu2xArt: .art
        case .waifu2xPhoto: .photo
        case .realCUGAN:
            switch denoise {
            case .off: .cugan
            case .automatic, .low: .cuganLow
            case .medium: .cuganMedium
            case .high: .cuganHigh
            }
        case .realESRGAN: .esrgan
        case .realSR: .realSR
        case .realSRJPEG: .realSRJPEG
        default: nil
        }
    }

    private static let compilationLock = NSLock()
    private static var compiled: [Kind: URL] = [:]
    let kind: Kind
    private let model: MLModel
    private let source: CVPixelBuffer

    init(kind: Kind) throws {
        self.kind = kind
        let url = try Self.compilationLock.withLock {
            if let cached = Self.compiled[kind] { return cached }
            let compiled = try compileBundledModel(kind.rawValue, kind.fileExtension)
            Self.compiled[kind] = compiled
            return compiled
        }
        model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
        let side = kind.tile + 2 * kind.halo
        // The converters already remove the halo, including CUGAN's valid convolutions.
        let input = model.modelDescription.inputDescriptionsByName["rgb"]?.imageConstraint
        let output = model.modelDescription.outputDescriptionsByName["result"]?.imageConstraint
        guard input?.pixelsWide == side, input?.pixelsHigh == side,
              output?.pixelsWide == kind.tile * kind.factor,
              output?.pixelsHigh == kind.tile * kind.factor else { throw UpscaleError.render }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer)
                == kCVReturnSuccess, let buffer else { throw UpscaleError.render }
        source = buffer
    }

    func scale(_ input: CIImage, context: CIContext, colorSpace: CGColorSpace) throws -> CIImage {
        let size = input.dimensions
        let tile = kind.tile
        let halo = kind.halo
        let factor = kind.factor
        guard kind.accepts(size) else { throw UpscaleError.neuralInputTooLarge }
        guard let result = CGContext(data: nil, width: size.width * factor, height: size.height * factor,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw UpscaleError.render }

        result.setBlendMode(.plusLighter)
        result.interpolationQuality = .none
        let padded = input.normalized.clampedToExtent()
        let side = tile + 2 * halo
        let features = try MLDictionaryFeatureProvider(dictionary: ["rgb": MLFeatureValue(pixelBuffer: source)])
        let columns = Self.tiles(length: size.width, tile: tile, factor: factor, alignment: kind.alignment)
        let rows = Self.tiles(length: size.height, tile: tile, factor: factor, alignment: kind.alignment)
        for row in rows {
            for column in columns {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let tileInput = padded.transformed(by: .init(translationX: CGFloat(halo - column.origin),
                                                                 y: CGFloat(halo - row.origin)))
                    context.render(tileInput, to: source, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                                   colorSpace: colorSpace)
                    let output = try model.prediction(from: features)
                    guard let pixels = output.featureValue(for: "result")?.imageBufferValue else {
                        throw UpscaleError.render
                    }
                    guard CVPixelBufferGetWidth(pixels) == tile * factor,
                          CVPixelBufferGetHeight(pixels) == tile * factor else { throw UpscaleError.render }
                    // CI coordinates stay bottom-left throughout. A short image occupies the
                    // bottom of the center tile, even though CVPixelBuffer rows run top-down.
                    let crop = CGRect(x: 0, y: 0, width: column.weights.count, height: row.weights.count)
                    let frame = CIImage(cvPixelBuffer: pixels, options: [.colorSpace: colorSpace])
                    guard let image = context.createCGImage(frame, from: crop, format: .RGBA8,
                                                            colorSpace: colorSpace) else { throw UpscaleError.render }
                    let weighted = try Self.weighted(image, columns: column.weights, rows: row.weights)
                    result.draw(weighted, in: crop.offsetBy(dx: Double(column.origin * factor), dy: Double(row.origin * factor)))
                }
            }
        }
        guard let image = result.makeImage() else { throw UpscaleError.render }
        return CIImage(cgImage: image)
    }

    static func weighted(_ image: CGImage, columns: [Float], rows: [Float]) throws -> CGImage {
        // CGImage raster rows are top-down; the tile weights use CI's bottom-left origin.
        let bytes = rows.reversed().flatMap { y in columns.map { UInt8((255 * $0 * y).rounded()) } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mask = CGImage(width: columns.count, height: rows.count, bitsPerComponent: 8,
                bitsPerPixel: 8, bytesPerRow: columns.count, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let weighted = image.masking(mask) else { throw UpscaleError.render }
        return weighted
    }

    // CUGAN's SE (and SAFMN's pooling) depends on each tile's entire content.
    // A halo alone cannot make their predictions identical at a hard cut. Blend
    // overlapping center tiles with separable weights that sum to one per pixel.
    static func tiles(length: Int, tile: Int, factor: Int, alignment: Int) -> [(origin: Int, weights: [Float])] {
        let step = tile * 3 / 4
        // Preserve the sampling phase of CUGAN's strided U-Net. On odd edges the
        // last center tile extends at most alignment - 1 pixels beyond the image.
        let span = (max(0, length - tile) + alignment - 1) / alignment * alignment
        let intervals = max(1, (span + step - 1) / step)
        let origins = span == 0 ? [0] : (0...intervals).map { $0 * span / intervals / alignment * alignment }
        let ramp = Float((tile - step) * factor)
        var totals = [Float](repeating: 0, count: length * factor)
        var tiles = origins.map { origin in
            let count = min(length - origin, tile) * factor
            let weights = (0..<count).map { pixel -> Float in
                let left = origin == 0 ? 1 : min(1, (Float(pixel) + 0.5) / ramp)
                let right = origin + tile >= length ? 1 : min(1, (Float(count - pixel) - 0.5) / ramp)
                return left * right
            }
            for pixel in 0..<count { totals[origin * factor + pixel] += weights[pixel] }
            return (origin: origin, weights: weights)
        }
        for index in tiles.indices {
            for pixel in tiles[index].weights.indices {
                tiles[index].weights[pixel] /= totals[tiles[index].origin * factor + pixel]
            }
        }
        return tiles
    }
}

func compileBundledModel(_ name: String, _ fileExtension: String) throws -> URL {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models/\(name).\(fileExtension)")
    if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
        return try MLModel.compileModel(at: bundled)
    }
    guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension,
                                      subdirectory: "Models") else { throw UpscaleError.render }
    return try MLModel.compileModel(at: url)
}
