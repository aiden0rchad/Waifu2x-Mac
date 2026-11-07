import Accelerate
import CoreImage
import Foundation

public struct ReferenceImage: Sendable, Equatable, Hashable {
    public let url: URL
    public var crop: CGRect?
    public init(url: URL, crop: CGRect? = nil) { self.url = url; self.crop = crop }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(crop != nil)
        if let crop { for value in [crop.minX, crop.minY, crop.width, crop.height] { hasher.combine(value) } }
    }

    public func pixelRect(in size: Dimensions) throws -> CGRect {
        let rect = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard size.width > 0, size.height > 0,
              [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { throw UpscaleError.invalidSize }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { throw UpscaleError.invalidSize }
        return CGRect(x: clipped.minX * CGFloat(size.width), y: clipped.minY * CGFloat(size.height),
                      width: clipped.width * CGFloat(size.width), height: clipped.height * CGFloat(size.height))
    }

    public static func preparedSize(_ size: CGSize) -> CGSize {
        let scale = min(1024, max(512, max(size.width, size.height))) / max(size.width, size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}

public enum RestoreGuard {
    // Protection weights: 1 repairs a hollow stroke with the base pixel; 0 keeps AI detail.
    public static func weights(base: [SIMD4<Float>], restored: [SIMD4<Float>], width: Int, height: Int) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / height,
              base.count == width * height, restored.count == base.count else { throw UpscaleError.invalidSize }
        var luma = [Float](repeating: 0, count: base.count)
        var restoredLuma = luma
        var core = luma
        for i in base.indices {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let b = base[i], r = restored[i]
            luma[i] = b.x * 0.2126 + b.y * 0.7152 + b.z * 0.0722
            restoredLuma[i] = r.x * 0.2126 + r.y * 0.7152 + r.z * 0.0722
            let saturation = max(b.x, b.y, b.z) - min(b.x, b.y, b.z)
            core[i] = luma[i] < 0.30 && saturation < 0.25 ? 1 : 0
        }
        core = try filter(core, width: width, height: height, rows: 3, columns: 3)
        let smooth = try blur(restoredLuma, width: width, height: height, sigma: 1)
        var hollow = luma
        for i in hollow.indices {
            if i % 16384 == 0 { try Task.checkCancellation() }
            hollow[i] = core[i] * min(1, max(0, (smooth[i] - luma[i] - 0.20) / 0.15))
        }
        hollow = try filter(hollow, width: width, height: height, rows: 3, columns: 3)
        hollow = try filter(hollow, width: width, height: height, rows: 3, columns: 3, maximum: true)
        hollow = try filter(hollow, width: width, height: height, rows: 9, columns: 9, maximum: true)
        let soft = try blur(hollow, width: width, height: height, sigma: 2)
        return try soft.indices.map { i in
            if i % 16384 == 0 { try Task.checkCancellation() }
            return min(1, max(0, 3 * soft[i]))
        }
    }

    static func blur(_ values: [Float], width: Int, height: Int, sigma: Int) throws -> [Float] {
        let radius = 3 * sigma
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / Float(2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        let count = UInt32(kernel.count)
        return try filter(filter(values, width: width, height: height, kernel: kernel, rows: 1, columns: count),
                          width: width, height: height, kernel: kernel, rows: count, columns: 1)
    }

    private static func filter(_ values: [Float], width: Int, height: Int, kernel: [Float]? = nil,
                               rows: UInt32, columns: UInt32, maximum: Bool = false) throws -> [Float] {
        try Task.checkCancellation()
        var result = [Float](repeating: 0, count: values.count)
        let error = values.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var dst = vImage_Buffer(data: output.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                if let kernel {
                    return vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, rows, columns, 0, vImage_Flags(kvImageEdgeExtend))
                }
                if maximum {
                    return vImageMax_PlanarF(&src, &dst, nil, 0, 0, vImagePixelCount(rows), vImagePixelCount(columns), vImage_Flags(kvImageEdgeExtend))
                }
                return vImageMin_PlanarF(&src, &dst, nil, 0, 0, vImagePixelCount(rows), vImagePixelCount(columns), vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw UpscaleError.render }
        try Task.checkCancellation()
        return result
    }
}

extension CIImage {
    func topLeftCrop(_ rect: CGRect) -> CIImage {
        let image = normalized
        // Fractional crop edges create partial alpha pixels in otherwise opaque
        // images, causing the opacity check to bypass Core ML upscaling.
        let pixels = CGRect(x: rect.minX, y: extent.height - rect.maxY, width: rect.width, height: rect.height)
            .integral.intersection(image.extent)
        return image.cropped(to: pixels).normalized
    }
}
