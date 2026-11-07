import CoreImage
import ImageIO
import XCTest
@testable import UpscaleCore

final class DiffusionRestoreTests: XCTestCase {
    func testCommandPreservesPathsPromptAndReferenceOrder() throws {
        var settings = RestoreSettings()
        settings.prompt = "Keep text 'hello'; $(touch nope)"
        settings.seed = 42
        let args = try MfluxCommand.arguments(model: URL(fileURLWithPath: "/model dir"),
            input: URL(fileURLWithPath: "/input image.png"), references: [URL(fileURLWithPath: "/reference.png")],
            output: URL(fileURLWithPath: "/out.png"), size: .init(width: 640, height: 784), settings: settings)
        XCTAssertEqual(Array(args.prefix(8)), ["--model", "/model dir", "--base-model", "flux2-klein-4b", "--image-paths", "/input image.png", "/reference.png", "--prompt"])
        XCTAssertEqual(args[8], settings.prompt + " " + MfluxCommand.referencePrompt)
        XCTAssertEqual(Array(args.suffix(10)), ["--steps", "4", "--width", "640", "--height", "784", "--seed", "42", "--output", "/out.png"])
        XCTAssertFalse(args.contains("--quantize"))
        settings.strength = .nan
        XCTAssertThrowsError(try MfluxCommand.arguments(model: URL(fileURLWithPath: "/m"), input: URL(fileURLWithPath: "/i"),
            references: [], output: URL(fileURLWithPath: "/o"), size: .init(width: 640, height: 784), settings: settings))
    }

    func testProgressHandlesChunksCarriageReturnsAndOtherTotals() {
        var parser = MfluxProgressParser()
        XCTAssertNil(parser.consume("Loading shards: 1/3 [00:01]\n"))
        XCTAssertEqual(parser.consume("\r  0%|          | 0/4 [00:00<?, ?it/s]"), 0)
        XCTAssertNil(parser.consume("\r 25%|██        | 1/"))
        XCTAssertEqual(parser.consume("4 [00:06<00:18, 6s/it]\r"), 0.25)
        XCTAssertEqual(parser.consume("\u{001B}[A 100%|████| 4/4 [00:25<00:00]\n"), 1)
        XCTAssertNil(parser.consume("0/4 [00:00]"))
    }

    func testStrengthEndpointsMidpointAndAlpha() throws {
        let base: [SIMD4<Float>] = [SIMD4(0.2, 0.4, 0.6, 0.5)]
        let edited: [SIMD4<Float>] = [SIMD4(0.8, 0.6, 0.4, 1)]
        XCTAssertEqual(try RestoreColour.pixels(base: base, restored: edited, keepColours: false, strength: 0), base)
        let full = try RestoreColour.pixels(base: base, restored: edited, keepColours: false, strength: 1)[0]
        XCTAssertEqual(full, SIMD4(0.8, 0.6, 0.4, 0.5))
        let half = try RestoreColour.pixels(base: base, restored: edited, keepColours: false, strength: 0.5)[0]
        XCTAssertEqual(half.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.z, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.w, 0.5)
        XCTAssertThrowsError(try RestoreColour.pixels(base: base, restored: [], keepColours: true, strength: 1))
    }

    func testLabRoundTripAndSyntheticMeanStdMatch() throws {
        let colours: [SIMD3<Double>] = [SIMD3(0.1, 0.2, 0.3), SIMD3(0.8, 0.7, 0.6), SIMD3(0.3, 0.6, 0.4)]
        for colour in colours {
            let back = RestoreColour.srgb(RestoreColour.lab(colour))
            for channel in 0..<3 { XCTAssertEqual(back[channel], colour[channel], accuracy: 0.00001) }
        }
        let base = colours.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let changed = colours.map { RestoreColour.srgb(RestoreColour.lab($0) * SIMD3(0.9, 0.8, 0.8) + SIMD3(3, 2, -2)) }
            .map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 1) }
        let matched = try RestoreColour.pixels(base: base, restored: changed, keepColours: true, strength: 1)
        for index in base.indices { for channel in 0..<4 { XCTAssertEqual(matched[index][channel], base[index][channel], accuracy: 0.0001) } }
        let flat = try RestoreColour.pixels(base: [SIMD4(0.2, 0.3, 0.4, 1)], restored: [SIMD4(0.8, 0.9, 0.6, 1)], keepColours: true, strength: 1)
        XCTAssertEqual(flat[0].x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(flat[0].z, 0.4, accuracy: 0.0001)
    }

    func testOldOptionsDecodeAndBaseDefaults() throws {
        let data = try JSONEncoder().encode(UpscaleOptions(preset: .photo))
        let options = try JSONDecoder().decode(UpscaleOptions.self, from: data)
        XCTAssertFalse(options.usesAI)
        XCTAssertEqual(options.restore.seed, 7)
        XCTAssertEqual(options.restore.base(for: options.preset), .realSR)
        XCTAssertEqual(options.restore.base(for: .illustration), .realCUGAN)
    }

    func testProcessFailureTailAndCancellation() async throws {
        do {
            try await EngineProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo restore-failed >&2; exit 3"])
            XCTFail("Process must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("restore-failed")) }
        let task = Task { try await EngineProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["20"]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { try await task.value; XCTFail("Process must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testRealFluxPipelineWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["W2X_FLUX_TEST"] == "1" else { throw XCTSkip("Set W2X_FLUX_TEST=1 to run the local FLUX pipeline") }
        try requireRestoreRendering()
        let pipeline = DiffusionRestore()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        var options = UpscaleOptions(preset: .realCUGAN)
        options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let referenceURL = folder.appendingPathComponent("reference.png")
        let renderer = FrameRenderer()
        try renderer.context.writePNGRepresentation(of: image, to: referenceURL, format: .RGBA8, colorSpace: renderer.colorSpace)
        let output = try await pipeline.render(image, to: .init(width: 128, height: 128), options: options,
            references: [ReferenceImage(url: referenceURL, crop: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))],
            renderer: renderer, progress: { _ in })
        XCTAssertEqual(output.image.dimensions, Dimensions(width: 128, height: 128))
        XCTAssertEqual(try FrameRenderer().image(output.image).width, 128)
    }

    func testRealFluxGIFPipelineWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["W2X_FLUX_TEST"] == "1" else { throw XCTSkip("Set W2X_FLUX_TEST=1 to run the local FLUX GIF pipeline") }
        try requireRestoreRendering()
        let pipeline = DiffusionRestore()
        var options = UpscaleOptions(preset: .realCUGAN)
        options.optionalEngineID = OptionalEngine.fluxKleinRestore.id
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try GIFRestoreTests.writeGIF(in: folder, frames: [0, 1, 0])
        let upscaler = Upscaler { image, size, options, references, renderer, progress in
            try await pipeline.render(image, to: size, options: options, references: references,
                renderer: renderer, progress: progress)
        }
        let result = try await upscaler.export(source, to: folder, options: options)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(reader), 3)
        for index in 0..<3 {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, index, nil))
            XCTAssertEqual(frame.width, 128)
            XCTAssertEqual(frame.height, 96)
        }
    }
}
