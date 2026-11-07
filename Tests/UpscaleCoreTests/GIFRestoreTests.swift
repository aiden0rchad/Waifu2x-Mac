import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UpscaleCore

final class GIFRestoreTests: XCTestCase {
    func testDuplicateFramePlan() {
        let plan = Upscaler.gifRestorePlan(["a", "b", "a", "c", "b"])
        XCTAssertEqual(plan.unique, [0, 1, 3])
        XCTAssertEqual(plan.mapping, [0, 1, 0, 2, 1])
        XCTAssertEqual(Upscaler.gifRestorePlan([String]()).unique, [])
        XCTAssertEqual(Upscaler.gifRestorePlan(["a", "a"]).mapping, [0, 0])
    }

    func testPixelHashIncludesSizeAndAlpha() throws {
        let image = try Self.frame(0, width: 8, height: 4)
        let reshaped = try Self.frame(0, width: 4, height: 8)
        XCTAssertNotEqual(try Upscaler.gifFrameHash(image), try Upscaler.gifFrameHash(reshaped))
        let transparent = try Self.frame(0, transparent: true, width: 8, height: 4)
        XCTAssertNotEqual(try Upscaler.gifFrameHash(image), try Upscaler.gifFrameHash(transparent))
        XCTAssertEqual(try Upscaler.gifFrameHash(image), try Upscaler.gifFrameHash(Self.frame(0, width: 8, height: 4)))
    }

    func testDecodedGIFFramesSharePixelHashes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for transparent in [false, true] {
            let url = try Self.writeGIF(in: folder, frames: [0, 1, 0, 2, 1], transparent: transparent)
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let hashes = try (0..<CGImageSourceGetCount(reader)).map {
                try Upscaler.gifFrameHash(XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, $0, nil)))
            }
            let plan = Upscaler.gifRestorePlan(hashes)
            XCTAssertEqual(plan.unique, [0, 1, 3])
            XCTAssertEqual(plan.mapping, [0, 1, 0, 2, 1])
        }
    }

    func testAIExportRestoresUniqueFramesAndKeepsTimingLoopAndAlpha() async throws {
        try requireRestoreRendering()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for transparent in [false, true] {
            let source = try Self.writeGIF(in: folder, frames: [0, 1, 0, 2, 1], transparent: transparent)
            let calls = RestoreCalls()
            let progress = GIFProgress()
            let upscaler = Upscaler { image, size, options, references, renderer, _ in
                let call = await calls.record(options, references: references)
                return RestoreResult(image: renderer.lanczos(image.applyingFilter("CIColorInvert"),
                    to: CGRect(x: 0, y: 0, width: size.width, height: size.height)),
                    outcome: call == 1 ? .restoredWithoutReferences : call == 2 ? .baseFallback : .restored)
            }
            var options = UpscaleOptions(preset: .fast)
            options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
            options.motionEngine = .rife // AI exports must never insert midpoints.
            options.restore.seed = 42
            options.restore.strength = 0.6
            options.restore.keepOriginalColours = false
            options.export.loopGIF = transparent
            if transparent { options.export.gifSpeed = .half }
            let references = (0..<4).map { ReferenceImage(url: folder.appendingPathComponent("reference-\($0).png")) }
            let output = try await upscaler.export(source, to: folder, options: options, references: references,
                restoreSummary: { await calls.summarize($0) }) {
                progress.append($0)
            }
            let recorded = await calls.values
            let reportedSummary = await calls.summary
            let summary = try XCTUnwrap(reportedSummary)
            XCTAssertEqual(summary.restoredWithoutReferences, 2)
            XCTAssertEqual(summary.baseFallback, 2)
            XCTAssertEqual(summary.restored, 1)
            XCTAssertEqual(recorded.count, 3)
            for call in recorded {
                XCTAssertEqual(call.options, options)
                XCTAssertEqual(call.references, references)
            }
            XCTAssertEqual(progress.values, [1.0 / 3, 2.0 / 3, 1, 1])
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(reader), 5)
            let properties = CGImageSourceCopyProperties(reader, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, transparent ? 0 : 3)
            var hashes: [String] = []
            let renderer = FrameRenderer()
            for index in 0..<5 {
                let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, index, nil))
                XCTAssertEqual(frame.width, 128)
                XCTAssertEqual(frame.height, 96)
                let properties = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any]
                let timing = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                XCTAssertEqual(try XCTUnwrap(timing?[kCGImagePropertyGIFUnclampedDelayTime] as? Double),
                    Double(index + 1) * (transparent ? 0.2 : 0.1), accuracy: 0.011)
                let image = CIImage(cgImage: frame)
                hashes.append(try Upscaler.gifFrameHash(frame).description)
                XCTAssertEqual(renderer.isOpaque(image), !transparent)
            }
            XCTAssertEqual(hashes[0], hashes[2])
            XCTAssertEqual(hashes[1], hashes[4])
            XCTAssertEqual(Set(hashes).count, 3)
            let first = CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil)))
            var pixel = [UInt8](repeating: 0, count: 4)
            renderer.context.render(first, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 40, y: 40, width: 1, height: 1), format: .RGBA8, colorSpace: renderer.colorSpace)
            XCTAssertLessThan(pixel[0], 10) // Red source becomes cyan.
            XCTAssertGreaterThan(pixel[1], 245)
            XCTAssertGreaterThan(pixel[2], 245)
        }
    }

    func testGIFPreviewSupportsWholeImageDetailAndBase() async throws {
        try requireRestoreRendering()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.writeGIF(in: folder, frames: [0, 1, 0])
        let calls = RestoreCalls()
        let upscaler = Upscaler { image, size, options, references, renderer, _ in
            await calls.record(options, references: references)
            return RestoreResult(image: renderer.lanczos(image, to: CGRect(x: 0, y: 0, width: size.width, height: size.height)), outcome: .baseFallback)
        }
        var options = UpscaleOptions(size: .custom, preset: .fast)
        options.customWidth = 32
        options.customHeight = 24
        options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
        let reference = ReferenceImage(url: folder.appendingPathComponent("reference.png"), crop: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        let base = try await upscaler.preview(source, options: options)
        XCTAssertNotEqual(base.method, OptionalEngine.fluxKleinRestore.name)
        let beforeGeneration = await calls.values
        XCTAssertTrue(beforeGeneration.isEmpty)
        for focus: CGPoint? in [nil, CGPoint(x: 0.5, y: 0.5)] {
            let preview = try await upscaler.preview(source, options: options, focus: focus,
                generateAI: true, references: [reference])
            XCTAssertEqual(preview.method, OptionalEngine.fluxKleinRestore.name)
            XCTAssertEqual(preview.output, Dimensions(width: 32, height: 24))
            XCTAssertEqual(preview.detail != nil, focus != nil)
            XCTAssertEqual(preview.restoreOutcome, .baseFallback)
        }
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded.allSatisfy { $0.references == [reference] })
    }

    func testPreviewCropsCachedExportPixelsAndInvalidatesForReferencesAndGuard() async throws {
        try requireRestoreRendering()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("preview.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 300, y: 0, width: 300, height: 400))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let calls = RestoreCalls()
        let upscaler = Upscaler { image, size, options, references, renderer, _ in
            await calls.record(options, references: references)
            XCTAssertEqual(size, Dimensions(width: 1200, height: 800))
            return RestoreResult(image: renderer.lanczos(image.applyingFilter("CIColorInvert"),
                to: CGRect(x: 0, y: 0, width: size.width, height: size.height)), outcome: .restored)
        }
        var options = UpscaleOptions(preset: .fast)
        options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
        let left = try await upscaler.preview(source, options: options, focus: CGPoint(x: 0.1, y: 0.5), generateAI: true)
        let right = try await upscaler.preview(source, options: options, focus: CGPoint(x: 0.9, y: 0.5), generateAI: true)
        let whole = try await upscaler.preview(source, options: options, generateAI: true)
        XCTAssertEqual(left.after.width, 512)
        XCTAssertNotEqual(try Upscaler.gifFrameHash(left.after), try Upscaler.gifFrameHash(right.after))
        let expectedLeft = try XCTUnwrap(whole.after.cropping(to: CGRect(x: 0, y: 144, width: 512, height: 512)))
        let expectedRight = try XCTUnwrap(whole.after.cropping(to: CGRect(x: 688, y: 144, width: 512, height: 512)))
        XCTAssertEqual(try Upscaler.gifFrameHash(left.after), try Upscaler.gifFrameHash(expectedLeft))
        XCTAssertEqual(try Upscaler.gifFrameHash(right.after), try Upscaler.gifFrameHash(expectedRight))
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 1)
        let crop = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.2)
        let reference = ReferenceImage(url: source, crop: crop)
        _ = try await upscaler.preview(source, options: options, generateAI: true, references: [reference])
        _ = try await upscaler.preview(source, options: options, generateAI: true, references: [ReferenceImage(url: source)])
        options.restore.protectStructure = false
        _ = try await upscaler.preview(source, options: options, generateAI: true, references: [ReferenceImage(url: source)])
        options.restore.characterDetails = "purple eyes"
        _ = try await upscaler.preview(source, options: options, generateAI: true, references: [ReferenceImage(url: source)])
        options.restore.safetyCheck = false
        _ = try await upscaler.preview(source, options: options, generateAI: true, references: [ReferenceImage(url: source)])
        let invalidated = await calls.values
        XCTAssertEqual(invalidated.count, 6)
    }

    func testCancellationDoesNotPublishPartialGIF() async throws {
        try requireRestoreRendering()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Self.writeGIF(in: folder, frames: [0, 1, 0])
        let upscaler = Upscaler { _, _, _, _, _, _ in throw CancellationError() }
        var options = UpscaleOptions()
        options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
        do {
            _ = try await upscaler.export(source, to: folder, options: options)
            XCTFail("Export must cancel")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [source.lastPathComponent])
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func writeGIF(in folder: URL, frames: [Int], transparent: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("fixture-\(UUID().uuidString).gif")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
        for (index, colour) in frames.enumerated() {
            CGImageDestinationAddImage(writer, try frame(colour, transparent: transparent), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: Double(index + 1) * 0.1]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private static func frame(_ colour: Int, transparent: Bool = false, width: Int = 64, height: Int = 48) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor([CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)][colour])
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if transparent { context.clear(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        return try XCTUnwrap(context.makeImage())
    }
}

private actor RestoreCalls {
    var values: [(options: UpscaleOptions, references: [ReferenceImage])] = []
    var summary: RestoreSummary?
    func summarize(_ summary: RestoreSummary) { self.summary = summary }
    @discardableResult func record(_ options: UpscaleOptions, references: [ReferenceImage]) -> Int {
        values.append((options, references)); return values.count
    }
}

private final class GIFProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}
