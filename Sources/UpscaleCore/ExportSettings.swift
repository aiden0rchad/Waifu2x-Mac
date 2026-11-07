import Foundation
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Codable, Sendable {
    case png = "PNG", jpeg = "JPEG"
    var type: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    case h264 = "H.264", hevc = "HEVC"
}

public enum VideoQuality: String, CaseIterable, Codable, Sendable {
    case compact = "Compact", balanced = "Balanced", high = "High"

    var bitsPerPixelPerFrame: Double {
        switch self {
        case .compact: 0.06
        case .balanced: 0.12
        case .high: 0.22
        }
    }
}

public enum DetailLevel: String, CaseIterable, Codable, Sendable {
    case automatic = "Auto", off = "Off", low = "Low", medium = "Medium", high = "High"

    func strength(default automatic: Double) -> Double {
        switch self {
        case .automatic: automatic
        case .off: 0
        case .low: 0.25
        case .medium: 0.5
        case .high: 0.85
        }
    }
}

public enum GIFSpeed: Double, CaseIterable, Codable, Sendable {
    case half = 0.5, original = 1, double = 2

    public var label: String {
        switch self {
        case .half: "½×"
        case .original: "Original"
        case .double: "2×"
        }
    }
}

public struct ExportSettings: Equatable, Codable, Sendable {
    public var imageFormat: ImageFormat = .png
    public var jpegQuality = 0.9
    public var filenameSuffix = " – Upscaled"
    public var videoCodec: VideoCodec = .h264
    public var videoQuality: VideoQuality = .balanced
    public var keepAudio = true
    public var gifSpeed: GIFSpeed = .original
    public var loopGIF = false

    public init() {}

    public func outputExtension(for kind: MediaKind) -> String {
        switch kind {
        case .image: imageFormat.fileExtension
        case .gif: "gif"
        case .video: "mp4"
        }
    }

    public func outputName(for source: URL, kind: MediaKind) -> String {
        let safeSuffix = filenameSuffix.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
        }
        var stem = source.deletingPathExtension().lastPathComponent
        let suffix = String(String.UnicodeScalarView(safeSuffix).prefix(24))
        while stem.utf8.count + suffix.utf8.count > 220, !stem.isEmpty { stem.removeLast() }
        return stem + suffix + "." + outputExtension(for: kind)
    }
}
