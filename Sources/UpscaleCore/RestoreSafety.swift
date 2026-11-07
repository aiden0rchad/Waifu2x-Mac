import CoreImage
import Foundation

public enum RestoreOutcome: Sendable, Equatable {
    case restored, restoredWithoutReferences, baseFallback

    public var note: String? {
        switch self {
        case .restored: nil
        case .restoredWithoutReferences: "AI: without references"
        case .baseFallback: "AI: base upscale only (safety check)"
        }
    }
}

struct RestoreResult {
    let image: CIImage
    let outcome: RestoreOutcome
}

public struct RestoreSummary: Sendable, Equatable {
    public private(set) var restored = 0
    public private(set) var restoredWithoutReferences = 0
    public private(set) var baseFallback = 0
    public init() {}

    mutating func record(_ outcome: RestoreOutcome) {
        switch outcome {
        case .restored: restored += 1
        case .restoredWithoutReferences: restoredWithoutReferences += 1
        case .baseFallback: baseFallback += 1
        }
    }

    public func note(for kind: MediaKind) -> String? {
        guard restoredWithoutReferences + baseFallback > 0 else { return nil }
        if kind != .gif {
            return (baseFallback > 0 ? RestoreOutcome.baseFallback : .restoredWithoutReferences).note
        }
        var parts: [String] = []
        if restoredWithoutReferences > 0 {
            parts.append("\(restoredWithoutReferences) \(restoredWithoutReferences == 1 ? "frame" : "frames") without references")
        }
        if baseFallback > 0 {
            parts.append("\(baseFallback) \(baseFallback == 1 ? "frame" : "frames") base only")
        }
        return "AI: " + parts.joined(separator: ", ")
    }
}

public enum RestoreSafety {
    public static let limit = 0.02

    public static func changedFraction(base: CIImage, result: CIImage) throws -> Double {
        let size = base.dimensions
        guard size.width > 0, size.height > 0, size == result.dimensions else { throw UpscaleError.invalidSize }
        try Task.checkCancellation()
        let scale = min(1, 390 / Double(max(size.width, size.height)))
        let width = max(1, Int((Double(size.width) * scale).rounded()))
        let height = max(1, Int((Double(size.height) * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let renderer = FrameRenderer()
        func luma(_ image: CIImage) -> [Float] {
            let small = scale < 1 ? renderer.lanczos(image.normalized, to: bounds) : image.normalized
            var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
            pixels.withUnsafeMutableBytes {
                renderer.context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: bounds, format: .RGBAf, colorSpace: renderer.colorSpace)
            }
            return pixels.map { p in
                p.w > 0 ? (0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z) / p.w : 0
            }
        }
        return try changedFraction(base: luma(base), result: luma(result), width: width, height: height)
    }

    // CPU metric also runs on hosts without IOSurface/Metal rendering services.
    static func changedFraction(base: [Float], result: [Float], width: Int, height: Int) throws -> Double {
        guard width > 0, height > 0, width <= Int.max / height,
              base.count == width * height, result.count == base.count else { throw UpscaleError.invalidSize }
        let original = try RestoreGuard.blur(base, width: width, height: height, sigma: 4)
        let restored = try RestoreGuard.blur(result, width: width, height: height, sigma: 4)
        let changed = original.indices.reduce(0) { $0 + (abs(original[$1] - restored[$1]) > 0.15 ? 1 : 0) }
        try Task.checkCancellation()
        return Double(changed) / Double(width * height)
    }
}
