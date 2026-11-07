import CoreImage
import Foundation
import ImageIO

public struct RestoreSettings: Codable, Equatable, Sendable {
    public static let defaultPrompt = "Restore this image: remove blur, compression artifacts and noise, sharpen line art and fine details. Keep the exact same composition, pose, character, colors and text."
    public var characterDetails = ""
    public var safetyCheck = true
    public var protectStructure = true
    public var prompt = defaultPrompt
    public var seed: UInt32 = 7
    public var keepOriginalColours = true
    public var strength: Double = 1
    public var baseEngine: Preset?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case prompt, characterDetails, safetyCheck, protectStructure, seed, keepOriginalColours, strength, baseEngine
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? Self.defaultPrompt
        characterDetails = String((try c.decodeIfPresent(String.self, forKey: .characterDetails) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        safetyCheck = try c.decodeIfPresent(Bool.self, forKey: .safetyCheck) ?? true
        protectStructure = try c.decodeIfPresent(Bool.self, forKey: .protectStructure) ?? true
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? 7
        keepOriginalColours = try c.decodeIfPresent(Bool.self, forKey: .keepOriginalColours) ?? true
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        baseEngine = try c.decodeIfPresent(Preset.self, forKey: .baseEngine)
    }

    public func base(for preset: Preset) -> Preset {
        let chosen = baseEngine ?? ([Preset.photo, .waifu2xPhoto, .realSR, .realSRJPEG].contains(preset) ? .realSR : .realCUGAN)
        return NeuralScaler.model(for: chosen) == nil ? .realCUGAN : chosen
    }
}

public enum MfluxCommand {
    public static let referencePrompt = "The first image is the one to restore; the other images are close-up references of the same character - use them only for the eyes and fine facial detail."
    public static func arguments(model: URL, input: URL, references: [URL], output: URL,
                                 size: Dimensions, settings: RestoreSettings) throws -> [String] {
        guard references.count <= 4, size.width >= 16, size.height >= 16,
              size.width % 16 == 0, size.height % 16 == 0,
              max(size.width, size.height) <= 1024, size.width * size.height <= 1_050_000,
              settings.strength.isFinite, (0...1).contains(settings.strength),
              !settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OptionalEngineError.message("Check AI Restore size, prompt, references and strength.")
        }
        let details = String(settings.characterDetails.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let prompt = settings.prompt + (details.isEmpty ? "" : " Character details: \(details).")
            + (references.isEmpty ? "" : " " + referencePrompt)
        return ["--model", model.path, "--base-model", "flux2-klein-4b", "--image-paths", input.path]
            + references.map(\.path) + ["--prompt", prompt, "--steps", "4", "--width", String(size.width),
                "--height", String(size.height), "--seed", String(settings.seed), "--output", output.path]
    }
}

public struct MfluxProgressParser: Sendable {
    private var buffer = ""
    private var last: Double = -1
    public init() {}
    public mutating func consume(_ text: String) -> Double? {
        buffer += text
        let regex = try! NSRegularExpression(pattern: #"\b([0-4])\s*/\s*4\s*\["#)
        var newest: Double?
        for match in regex.matches(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)) {
            if let range = Range(match.range(at: 1), in: buffer), let step = Double(buffer[range]), step / 4 > last {
                last = step / 4; newest = last
            }
        }
        // Keep only the trailing partial record; tqdm uses carriage returns.
        if let index = buffer.lastIndex(where: { $0 == "\r" || $0 == "\n" }) { buffer = String(buffer[buffer.index(after: index)...]) }
        if buffer.count > 1024 { buffer = String(buffer.suffix(1024)) }
        return newest
    }
}

public struct DiffusionRestore: Sendable {
    typealias Runner = @Sendable (URL, [String], @escaping @Sendable (String) -> Void) async throws -> Void
    private let runner: Runner
    private let paths: EnginePaths
    private let testRuntime: (executable: URL, model: URL)?
    public init(paths: EnginePaths = EnginePaths()) {
        self.paths = paths; testRuntime = nil; runner = Self.run
    }
    init(executable: URL, model: URL, runner: @escaping Runner = Self.run) {
        paths = EnginePaths(); testRuntime = (executable, model); self.runner = runner
    }

    static let run: Runner = { executable, arguments, output in
        try await EngineProcess.run(executable, arguments,
            environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                          "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1", "TOKENIZERS_PARALLELISM": "false"],
            output: output)
    }

    func render(_ source: CIImage, to target: Dimensions, options: UpscaleOptions,
                references: [ReferenceImage], renderer: FrameRenderer,
                progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreResult {
        try Task.checkCancellation()
        guard references.count <= 4 else { throw OptionalEngineError.message("Use up to four reference images.") }
        let runtime: (executable: URL, model: URL)
        if let testRuntime { runtime = testRuntime }
        else {
            do { try paths.verify(.fluxKleinRestore) }
            catch { throw OptionalEngineError.message("AI Restore is missing or incomplete. Download in Engines.") }
            runtime = (paths.executable, paths.model(.fluxKleinRestore))
        }
        guard ProcessInfo.processInfo.physicalMemory >= 16_000_000_000 else {
            throw OptionalEngineError.message("AI Restore needs at least 16 GB of memory. Close other apps if memory is low.")
        }
        let settings = options.restore
        var baseOptions = options
        baseOptions.optionalEngineID = nil
        baseOptions.preset = settings.base(for: options.preset)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w2x-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var prepared: [URL] = []
        for (index, reference) in references.enumerated() {
            try Task.checkCancellation()
            guard let image = CIImage(contentsOf: reference.url, options: [.applyOrientationProperty: true]) else {
                throw OptionalEngineError.message("Cannot read reference image: \(reference.url.lastPathComponent).")
            }
            let crop = image.topLeftCrop(try reference.pixelRect(in: image.dimensions))
            let size = ReferenceImage.preparedSize(crop.extent.size)
            let url = directory.appendingPathComponent("reference-\(index).png")
            try renderer.context.writePNGRepresentation(of: renderer.lanczos(crop, to: CGRect(origin: .zero, size: size)),
                to: url, format: .RGBA8, colorSpace: renderer.colorSpace)
            prepared.append(url)
        }
        let size = try RestorePlanner.intermediate(source: source.dimensions, target: target)
        let base = try await renderer.scale(source, to: size, options: baseOptions, opaque: renderer.isOpaque(source))
        progress(0.1)
        let chosen = try await restoreIntermediate(base, references: prepared, executable: runtime.executable,
            model: runtime.model, directory: directory, settings: settings, renderer: renderer, progress: progress)
        let blended = try RestoreColour.blend(base: base, restored: chosen.image, strength: settings.strength, renderer: renderer)
        progress(0.9)
        let result = try await renderer.scale(blended, to: target, options: baseOptions, opaque: renderer.isOpaque(base))
        progress(1)
        return RestoreResult(image: result, outcome: chosen.outcome)
    }

    // Shared by images, GIF frames and previews; tests inject only the mflux runner.
    func restoreIntermediate(_ base: CIImage, references: [URL], executable: URL, model: URL,
                             directory: URL, settings: RestoreSettings, renderer: FrameRenderer,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> RestoreResult {
        let input = directory.appendingPathComponent("main-input.png")
        try renderer.context.writePNGRepresentation(of: base, to: input, format: .RGBA8, colorSpace: renderer.colorSpace)
        var attempts: [([URL], UInt32)] = [(references, settings.seed)]
        if settings.safetyCheck {
            if !references.isEmpty { attempts.append(([], settings.seed)) }
            attempts.append(([], settings.seed &+ 1))
        }
        var start = 0.1
        for (index, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            var current = settings
            current.seed = attempt.1
            let output = directory.appendingPathComponent("output-\(index).png")
            let arguments = try MfluxCommand.arguments(model: model, input: input, references: attempt.0,
                output: output, size: base.dimensions, settings: current)
            // Reserve half the remaining range for each retry; the bar never retreats.
            let end = index == attempts.count - 1 ? 0.85 : start + (0.85 - start) / 2
            let parser = RestoreProgressSink(start: start, end: end, progress: progress)
            try await runner(executable, arguments) { parser.consume($0) }
            try Task.checkCancellation()
            guard let restored = CIImage(contentsOf: output), restored.dimensions == base.dimensions else {
                throw OptionalEngineError.message("AI Restore did not produce an image of the expected size.")
            }
            current.strength = 1 // Safety sees the full edit, before the user's Strength blend.
            let matched = try RestoreColour.finish(base: base, restored: restored, settings: current, renderer: renderer)
            progress(end)
            let fraction = settings.safetyCheck ? try RestoreSafety.changedFraction(base: base, result: matched) : 0
            if fraction <= RestoreSafety.limit {
                let outcome: RestoreOutcome = !references.isEmpty && attempt.0.isEmpty ? .restoredWithoutReferences : .restored
                return RestoreResult(image: matched, outcome: outcome)
            }
            start = end
        }
        try Task.checkCancellation()
        return RestoreResult(image: base, outcome: .baseFallback)
    }
}

private final class RestoreProgressSink: @unchecked Sendable {
    private var parser = MfluxProgressParser()
    private let progress: @Sendable (Double) -> Void
    private let start: Double
    private let end: Double
    init(start: Double, end: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.start = start; self.end = end; self.progress = progress
    }
    // Called only by the process's output-draining queue.
    func consume(_ text: String) { if let value = parser.consume(text) { progress(start + value * (end - start)) } }
}

enum RestoreColour {
    // Unpremultiplied sRGB pixels. Preserve source alpha through matching and blending.
    static func pixels(base: [SIMD4<Float>], restored: [SIMD4<Float>], keepColours: Bool, strength: Double) throws -> [SIMD4<Float>] {
        guard base.count == restored.count, !base.isEmpty, strength.isFinite, (0...1).contains(strength) else {
            throw OptionalEngineError.message("Invalid AI colour blend.")
        }
        if strength == 0 { return base }
        var edited: [SIMD3<Double>] = []
        if keepColours {
            let original = base.map { lab(SIMD3(Double($0.x), Double($0.y), Double($0.z))) }
            edited = restored.map { lab(SIMD3(Double($0.x), Double($0.y), Double($0.z))) }
            let indices = base.indices.filter { base[$0].w > 0.01 && restored[$0].w > 0.01 }
            if !indices.isEmpty {
                let count = Double(indices.count)
                let meanA = indices.reduce(SIMD3<Double>.zero) { $0 + original[$1] } / count
                let meanB = indices.reduce(SIMD3<Double>.zero) { $0 + edited[$1] } / count
                let varA = indices.reduce(SIMD3<Double>.zero) { let d = original[$1] - meanA; return $0 + d * d } / count
                let varB = indices.reduce(SIMD3<Double>.zero) { let d = edited[$1] - meanB; return $0 + d * d } / count
                let ratio = SIMD3(sqrt(varA.x / max(1e-8, varB.x)), sqrt(varA.y / max(1e-8, varB.y)), sqrt(varA.z / max(1e-8, varB.z)))
                edited = edited.map { ($0 - meanB) * ratio + meanA }
            }
        }
        return try base.indices.map { index in
            if index % 16384 == 0 { try Task.checkCancellation() }
            let rgb = keepColours ? srgb(edited[index]) : SIMD3(Double(restored[index].x), Double(restored[index].y), Double(restored[index].z))
            let a = base[index], s = Float(strength)
            return SIMD4(a.x * (1 - s) + Float(min(1, max(0, rgb.x))) * s,
                         a.y * (1 - s) + Float(min(1, max(0, rgb.y))) * s,
                         a.z * (1 - s) + Float(min(1, max(0, rgb.z))) * s, a.w)
        }
    }

    static func finish(base: CIImage, restored: CIImage, settings: RestoreSettings, renderer: FrameRenderer) throws -> CIImage {
        let size = base.dimensions
        func read(_ image: CIImage) -> [SIMD4<Float>] {
            var pixels = [SIMD4<Float>](repeating: .zero, count: size.width * size.height)
            pixels.withUnsafeMutableBytes {
                renderer.context.render(image, toBitmap: $0.baseAddress!, rowBytes: size.width * 16,
                                        bounds: base.extent, format: .RGBAf, colorSpace: renderer.colorSpace)
            }
            return pixels.map { pixel in pixel.w > 0 ? SIMD4(pixel.x / pixel.w, pixel.y / pixel.w, pixel.z / pixel.w, pixel.w) : .zero }
        }
        let original = read(base)
        var matched = try pixels(base: original, restored: read(restored), keepColours: settings.keepOriginalColours, strength: 1)
        if settings.protectStructure {
            let weights = try RestoreGuard.weights(base: original, restored: matched, width: size.width, height: size.height)
            for i in matched.indices {
                if i % 16384 == 0 { try Task.checkCancellation() }
                matched[i] = matched[i] * (1 - weights[i]) + original[i] * weights[i]
            }
        }
        let result = try pixels(base: original, restored: matched, keepColours: false, strength: settings.strength)
            .map { SIMD4($0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w) }
        let data = result.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: size.width * 16, size: CGSize(width: size.width, height: size.height),
                       format: .RGBAf, colorSpace: renderer.colorSpace)
    }

    static func blend(base: CIImage, restored: CIImage, strength: Double, renderer: FrameRenderer) throws -> CIImage {
        if strength == 0 { return base }
        if strength == 1 { return restored }
        var settings = RestoreSettings()
        settings.keepOriginalColours = false
        settings.protectStructure = false
        settings.strength = strength
        return try finish(base: base, restored: restored, settings: settings, renderer: renderer)
    }

    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func f(_ v: Double) -> Double { v > 216.0 / 24389 ? cbrt(v) : (24389.0 / 27 * v + 16) / 116 }
        let r = linear(rgb.x), g = linear(rgb.y), b = linear(rgb.z)
        let x = f((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047)
        let y = f(0.2126729 * r + 0.7151522 * g + 0.0721750 * b)
        let z = f((0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883)
        return SIMD3(116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    static func srgb(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ v: Double) -> Double { v > 6.0 / 29 ? v * v * v : 3 * pow(6.0 / 29, 2) * (v - 4.0 / 29) }
        func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let y = (lab.x + 16) / 116, x = f(y + lab.y / 500) * 0.95047, z = f(y - lab.z / 200) * 1.08883, yy = f(y)
        return SIMD3(gamma(3.2404542 * x - 1.5371385 * yy - 0.4985314 * z),
                     gamma(-0.969266 * x + 1.8760108 * yy + 0.041556 * z),
                     gamma(0.0556434 * x - 0.2040259 * yy + 1.0572252 * z))
    }
}
