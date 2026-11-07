import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UpscaleCore

final class UpscaleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testPNGKeepsTransparencyAndConcurrentExportsGetDifferentNames() async throws {
        let source = folder.appendingPathComponent("Artwork.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try fixture(transparent: true), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let input = try Data(contentsOf: source)

        async let first = Upscaler().export(source, to: folder, options: UpscaleOptions(preset: .fast))
        async let second = Upscaler().export(source, to: folder, options: UpscaleOptions(preset: .anime4k))
        let outputs = try await [first, second]
        XCTAssertEqual(Set(outputs).count, 2)
        XCTAssertEqual(try Data(contentsOf: source), input)
        for url in outputs {
            let image = try readImage(url)
            XCTAssertEqual(image.width, 80)
            XCTAssertEqual(image.height, 48)
            let pixels = try XCTUnwrap(image.dataProvider?.data)
            let alpha = try XCTUnwrap(CFDataGetBytePtr(pixels))
            XCTAssertEqual(image.bitsPerPixel, 32)
            XCTAssertEqual(alpha[3], 0, "The transparent corner must survive export")
            XCTAssertGreaterThan(alpha[image.bytesPerRow * 24 + 40 * 4 + 3], 240)
        }
    }

    func testOpaqueFastExportAndFitPreview() async throws {
        let source = folder.appendingPathComponent("Photo.jpg")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try fixture(transparent: false), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let engine = Upscaler()
        let preview = try await engine.preview(source, options: UpscaleOptions(size: .hd, preset: .fast))
        XCTAssertEqual(preview.input, Dimensions(width: 40, height: 24))
        XCTAssertEqual(preview.output, Dimensions(width: 1800, height: 1080))

        let result = try await engine.export(source, to: folder, options: UpscaleOptions(preset: .fast))
        let image = try readImage(result)
        XCTAssertEqual(image.width, 80)
        XCTAssertEqual(image.height, 48)
    }

    func testBundledModelsRenderDistinctUprightImagesAcrossTiles() async throws {
        let source = folder.appendingPathComponent("Color bands.jpg")
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 237, height: 213, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(red: 0.05, green: 0.15, blue: 0.85, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: 237, height: 106))
        canvas.setFillColor(red: 0.8, green: 0.25, blue: 0.05, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 106, width: 237, height: 107))
        canvas.setFillColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        canvas.fill(CGRect(x: 189, y: 36, width: 4, height: 137))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(canvas.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let engine = Upscaler()
        var renders: [Data] = []
        let models: [(Preset, DetailLevel)] = [
            (.anime4k, .automatic), (.anime4kRestore, .automatic), (.waifu2xArt, .automatic),
            (.waifu2xPhoto, .automatic), (.realCUGAN, .off), (.realCUGAN, .low),
            (.realCUGAN, .medium), (.realCUGAN, .high), (.realESRGAN, .automatic),
            (.realSR, .automatic), (.realSRJPEG, .automatic)
        ]
        for (preset, denoise) in models {
            var options = UpscaleOptions(preset: preset)
            options.noiseReduction = denoise
            let preview = try await engine.preview(source, options: options)
            XCTAssertEqual(preview.method, preset.rawValue)
            let result = try await engine.export(source, to: folder, options: options)
            let image = try readImage(result)
            XCTAssertEqual(image.width, 474)
            XCTAssertEqual(image.height, 426)
            let renderer = FrameRenderer()
            let rgba = try renderer.image(CIImage(cgImage: image))
            let data = try XCTUnwrap(rgba.dataProvider?.data) as Data
            func pixel(_ x: Int, _ y: Int, _ channel: Int) -> Int {
                Int(data[y * rgba.bytesPerRow + 4 * x + channel])
            }
            XCTAssertGreaterThan(pixel(40, 20, 0), 150, "The top stays red")
            XCTAssertGreaterThan(pixel(40, 400, 2), 150, "The bottom stays blue")
            XCTAssertGreaterThan(pixel(450, 20, 0), 150, "The partial right tile is drawn")
            let boundary = try XCTUnwrap(NeuralScaler.model(for: preset, denoise: denoise)).tile * 2
            XCTAssertLessThan(abs(pixel(boundary - 1, 402, 2) - pixel(boundary, 402, 2)), 8,
                              "No seam through a flat color for \(preset.rawValue)")
            renders.append(data)
        }
        XCTAssertEqual(Set(renders).count, models.count, "Every checkpoint should produce a distinct result")
    }

    func testAppleMLUsesNativeModelOnSupportedInput() async throws {
        let input = Dimensions(width: 512, height: 512)
        let output = Dimensions(width: 1024, height: 1024)
        guard #available(macOS 26, *), SuperResolution.isAvailable,
              SuperResolution.supports(input, output: output) else { throw XCTSkip("Apple ML scaler unavailable") }
        let source = folder.appendingPathComponent("ML.jpg")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let frame = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        CGImageDestinationAddImage(writer, try FrameRenderer().image(frame), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let preview = try await Upscaler().preview(source, options: UpscaleOptions(preset: .enhance))
        XCTAssertEqual(preview.method, "Apple ML")
        XCTAssertEqual(preview.after.width, 1024)
        let data = try XCTUnwrap(preview.after.dataProvider?.data)
        let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
        let center = 512 * preview.after.bytesPerRow + 512 * 4
        XCTAssertGreaterThan(pixels[center + 2], 140, "The rendered frame should retain its blue channel")
    }

    func testGIFKeepsFrameCountTimingAndLoop() async throws {
        let source = folder.appendingPathComponent("Animation.gif")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]
        ] as CFDictionary)
        for delay in [0.12, 0.27] {
            CGImageDestinationAddImage(writer, try fixture(transparent: true), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let result = try await Upscaler().export(source, to: folder, options: UpscaleOptions())
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(result as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(reader), 2)
        let global = CGImageSourceCopyProperties(reader, nil) as? [CFString: Any]
        let gif = global?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 3)
        for (index, expected) in [0.12, 0.27].enumerated() {
            let props = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any]
            let timing = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = try XCTUnwrap(timing?[kCGImagePropertyGIFDelayTime] as? Double)
            XCTAssertEqual(delay, expected, accuracy: 0.011)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, index, nil))
            XCTAssertEqual(image.width, 80)
            XCTAssertEqual(image.height, 48)
        }

        var options = UpscaleOptions()
        options.export.gifSpeed = .half
        options.export.loopGIF = true
        let slowed = try await Upscaler().export(source, to: folder, options: options)
        let slowReader = try XCTUnwrap(CGImageSourceCreateWithURL(slowed as CFURL, nil))
        let slowGlobal = CGImageSourceCopyProperties(slowReader, nil) as? [CFString: Any]
        let slowGIF = slowGlobal?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(slowGIF?[kCGImagePropertyGIFLoopCount] as? Int, 0)
        let slowFrame = CGImageSourceCopyPropertiesAtIndex(slowReader, 0, nil) as? [CFString: Any]
        let slowTiming = slowFrame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(try XCTUnwrap(slowTiming?[kCGImagePropertyGIFDelayTime] as? Double), 0.24, accuracy: 0.011)
    }

    func testCustomSizeAndJPEGSettingsReachExport() async throws {
        let source = folder.appendingPathComponent("Artwork.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try fixture(transparent: true), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        var options = UpscaleOptions(size: .custom)
        options.customWidth = 100
        options.customHeight = 100
        options.export.imageFormat = .jpeg
        options.export.jpegQuality = 0.6
        options.export.filenameSuffix = "-proof"
        let preview = try await Upscaler().preview(source, options: options)
        XCTAssertEqual(preview.output, Dimensions(width: 100, height: 60))

        options.fitInside = false
        let output = try await Upscaler().export(source, to: folder, options: options)
        XCTAssertEqual(output.lastPathComponent, "Artwork-proof.jpg")
        let image = try readImage(output)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertGreaterThan(pixels[0], 240, "JPEG should flatten transparent corners to white")
    }

    func testVideoKeepsPortraitOrientationDurationAndAudio() async throws {
        let source = try await videoFixture()
        let preview = try await Upscaler().preview(source, options: UpscaleOptions())
        XCTAssertEqual(preview.input, Dimensions(width: 48, height: 64))

        let result = try await Upscaler().export(source, to: folder, options: UpscaleOptions(preset: .anime4k))
        let asset = AVURLAsset(url: result)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let size = try await XCTUnwrap(videos.first).load(.naturalSize)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(size, CGSize(width: 96, height: 128))
        XCTAssertEqual(audios.count, 1)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
    }

    func testVideoAIEnginesPreserveFramesAndAudioAcrossWindows() async throws {
        let source = try await videoFixture(width: 96, height: 64, frameCount: 15)
        let upscaler = Upscaler()
        var renders = Set<Data>()
        for engine in [VideoEngine.safmn, .nano, .nanoDetail] {
            var options = UpscaleOptions(size: .quadruple, preset: .fast, smootherMotion: engine.isTemporal)
            options.videoEngine = engine
            let preview = try await upscaler.preview(source, options: options)
            XCTAssertEqual(preview.method, engine.rawValue)
            XCTAssertEqual(preview.output, Dimensions(width: 256, height: 384))
            renders.insert(try XCTUnwrap(preview.after.dataProvider?.data) as Data)
            let result = try await upscaler.export(source, to: folder, options: options)

            let asset = AVURLAsset(url: result)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1)
            let track = try XCTUnwrap(video.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 256, height: 384))

            let reader = try AVAssetReader(asset: asset)
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(samples)
            XCTAssertTrue(reader.startReading())
            var timestamps: [Double] = []
            while let sample = samples.copyNextSampleBuffer() { timestamps.append(sample.presentationTimeStamp.seconds) }
            XCTAssertEqual(timestamps.count, 15, "No frame may be repeated or dropped at a model window boundary")
            for (index, time) in timestamps.enumerated() {
                XCTAssertEqual(time, Double(index) / 15, accuracy: 0.002)
            }
        }
        XCTAssertEqual(renders.count, 3, "Every model should produce a distinct preview")
    }

    func testDetailCropCentredAtNativeResolution() throws {
        let detail = try DetailGeometry(imageSize: Dimensions(width: 1920, height: 1080),
                                        focus: CGPoint(x: 0.5, y: 0.5), scale: CGSize(width: 2, height: 2))
        XCTAssertEqual(detail.rect, CGRect(x: 832, y: 412, width: 256, height: 256))
        XCTAssertEqual(detail.output, Dimensions(width: 512, height: 512))
    }

    func testDetailCropClampsEdgesAndSmallInputs() throws {
        let size = Dimensions(width: 1000, height: 600)
        let topLeft = try DetailGeometry(imageSize: size, focus: CGPoint(x: -1, y: 0), scale: CGSize(width: 3, height: 3))
        XCTAssertEqual(topLeft.rect, CGRect(x: 0, y: 0, width: 256, height: 256))
        let bottomRight = try DetailGeometry(imageSize: size, focus: CGPoint(x: 1, y: 2), scale: CGSize(width: 3, height: 3))
        XCTAssertEqual(bottomRight.rect, CGRect(x: 744, y: 344, width: 256, height: 256))
        XCTAssertEqual(bottomRight.output, Dimensions(width: 768, height: 768))
        let small = try DetailGeometry(imageSize: Dimensions(width: 40, height: 300),
                                      focus: CGPoint(x: 0.9, y: 0.5), scale: CGSize(width: 4, height: 4))
        XCTAssertEqual(small.rect, CGRect(x: 0, y: 22, width: 40, height: 256))
        XCTAssertEqual(small.output, Dimensions(width: 160, height: 1024))
    }

    func testDetailCropUsesExportScalesAndValidatesGeometry() throws {
        let size = Dimensions(width: 1001, height: 601)
        var options = UpscaleOptions(size: .custom)
        options.customWidth = 1500
        options.customHeight = 700
        options.fitInside = false
        let output = try options.dimensions(for: size, video: true)
        let detail = try DetailGeometry(imageSize: size, focus: CGPoint(x: 0.333, y: 0.777),
                                        scale: CGSize(width: Double(output.width) / 1001, height: Double(output.height) / 601))
        XCTAssertEqual(detail.rect, CGRect(x: 205, y: 339, width: 256, height: 256))
        XCTAssertEqual(detail.output, Dimensions(width: 384, height: 298))
        for scale in [CGSize(width: 0, height: 2), CGSize(width: CGFloat.infinity, height: 2), CGSize(width: 1000, height: 1000)] {
            XCTAssertThrowsError(try DetailGeometry(imageSize: size, focus: .zero, scale: scale))
        }
        XCTAssertThrowsError(try DetailGeometry(imageSize: size, focus: CGPoint(x: Double.nan, y: 0), scale: CGSize(width: 2, height: 2)))
        XCTAssertThrowsError(try DetailGeometry(imageSize: Dimensions(width: 0, height: 1), focus: .zero, scale: CGSize(width: 2, height: 2)))
    }

    func testWorkspaceSettingsRoundTrip() throws {
        var settings = WorkspaceSettings()
        settings.options = UpscaleOptions(size: .triple, preset: .realSR)
        settings.options.motionEngine = .rife
        settings.options.videoEngine = .nano
        settings.folderPath = folder.path
        settings.besideOriginals = false
        settings.keepAwake = false
        settings.revealWhenDone = true
        XCTAssertEqual(WorkspaceSettings.restore(from: try JSONEncoder().encode(settings)), settings)
    }

    func testWorkspaceSettingsFallbackAndMissingFolder() throws {
        XCTAssertEqual(WorkspaceSettings.restore(from: nil), WorkspaceSettings())
        for data in [Data("invalid".utf8), Data("{}".utf8), Data("{\"options\":{\"preset\":\"removed\"}}".utf8)] {
            XCTAssertEqual(WorkspaceSettings.restore(from: data), WorkspaceSettings())
        }
        XCTAssertEqual(WorkspaceSettings().options.preset, .realCUGAN)
        var settings = WorkspaceSettings()
        settings.besideOriginals = false
        settings.folderPath = folder.appendingPathComponent("missing").path
        XCTAssertNil(WorkspaceSettings.restore(from: try JSONEncoder().encode(settings)).folderPath)
        settings.folderPath = folder.appendingPathComponent("file").path
        XCTAssertTrue(FileManager.default.createFile(atPath: settings.folderPath!, contents: Data()))
        XCTAssertNil(WorkspaceSettings.restore(from: try JSONEncoder().encode(settings)).folderPath)
    }

    func testVideoEngineMigratesOlderPresets() throws {
        let current = try JSONEncoder().encode(UpscaleOptions())
        var previous = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        previous["temporalVideo"] = true
        previous["smootherMotion"] = true
        let old = try JSONSerialization.data(withJSONObject: previous)
        var options = try JSONDecoder().decode(UpscaleOptions.self, from: old)
        XCTAssertEqual(options.videoEngine, .nano)
        XCTAssertEqual(options.motionEngine, .apple)
        options.videoEngine = .safmn
        let saved = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(UpscaleOptions.self, from: saved).videoEngine, .safmn)
        options.motionEngine = .rife
        XCTAssertEqual(try JSONDecoder().decode(UpscaleOptions.self, from: JSONEncoder().encode(options)).motionEngine, .rife)
    }

    func testSmootherMotionAddsIntermediateFramesAndKeepsAudio() async throws {
        let source = try await videoFixture(width: 320, height: 240)
        try await checkInterpolatedVideo(source, engine: .rife)
        if UpscaleOptions.canInterpolateVideo { try await checkInterpolatedVideo(source, engine: .apple) }
    }

    private func checkInterpolatedVideo(_ source: URL, engine: MotionEngine) async throws {
        var options = UpscaleOptions(preset: .fast)
        options.motionEngine = engine
        let output = try await Upscaler().export(source, to: folder, options: options)
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let track = try XCTUnwrap(videos.first)
        let videoDuration = try await track.load(.timeRange).duration
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(samples)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = samples.copyNextSampleBuffer() { times.append(sample.presentationTimeStamp.seconds) }
        XCTAssertEqual(times.count, 15, "Expected 8 originals and 7 intermediate frames. Got \(times)")
        for (index, time) in times.enumerated() {
            XCTAssertEqual(time, Double(index) / 16, accuracy: 0.002)
        }
        XCTAssertEqual(audios.count, 1)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.15)
        XCTAssertEqual(videoDuration.seconds, 1, accuracy: 0.002)
    }

    func testGIFInterpolationPlanCountsOnlyEligiblePairs() {
        let size = Dimensions(width: 40, height: 24)
        var frames = [(size: size, opaque: true, delay: 0.02),
                      (size: size, opaque: true, delay: 0.14),
                      (size: size, opaque: false, delay: 0.19)]
        var plan = Upscaler.gifMidpoints(frames, enabled: true)
        XCTAssertEqual(plan, [false, false, false])
        XCTAssertEqual(frames.count + plan.filter { $0 }.count, 3)
        frames[0].delay = 0.04
        plan = Upscaler.gifMidpoints(frames, enabled: true)
        XCTAssertEqual(plan, [true, false, false])
        XCTAssertEqual(frames.count + plan.filter { $0 }.count, 4)
        frames[1].size = Dimensions(width: 41, height: 24)
        XCTAssertEqual(Upscaler.gifMidpoints(frames, enabled: true), [false, false, false])
        frames[1].size = size
        frames[2].opaque = true
        XCTAssertEqual(Upscaler.gifMidpoints(frames, enabled: true), [true, true, false])
        XCTAssertEqual(Upscaler.gifMidpoints(frames, enabled: false), [false, false, false])
    }

    func testRIFEGIFSkipsShortAndTransparentPairs() async throws {
        let source = folder.appendingPathComponent("Mixed.gif")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for (index, delay) in [0.02, 0.14, 0.19].enumerated() {
            CGImageDestinationAddImage(writer, try fixture(transparent: index == 2), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        var options = UpscaleOptions(preset: .fast)
        options.motionEngine = .rife
        let output = try await Upscaler().export(source, to: folder, options: options)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(reader), 3)
        for (index, expected) in [0.02, 0.14, 0.19].enumerated() {
            let properties = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any]
            let timing = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            XCTAssertEqual(try XCTUnwrap(timing?[kCGImagePropertyGIFUnclampedDelayTime] as? Double),
                           expected, accuracy: 0.009)
        }
    }

    func testRIFEGIFAddsFramesAndKeepsLoopTiming() async throws {
        for transparent in [false, true] {
            let source = folder.appendingPathComponent(transparent ? "Alpha.gif" : "Opaque.gif")
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(
                source as CFURL, UTType.gif.identifier as CFString, 3, nil
            ))
            CGImageDestinationSetProperties(writer, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]
            ] as CFDictionary)
            for (index, delay) in [0.14, 0.03, 0.19].enumerated() {
                let image = CIImage(cgImage: try fixture(transparent: transparent))
                let frame = image.transformed(by: .init(translationX: CGFloat(index * 3), y: 0))
                    .cropped(to: image.extent)
                let input = transparent ? frame : frame.composited(over: CIImage(color: .black).cropped(to: frame.extent))
                CGImageDestinationAddImage(writer, try FrameRenderer().image(input), [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]
                ] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            var options = UpscaleOptions(preset: .fast)
            options.motionEngine = .rife
            let output = try await Upscaler().export(source, to: folder, options: options)
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let expected = transparent ? [0.14, 0.03, 0.19] : [0.07, 0.07, 0.03, 0.19]
            XCTAssertEqual(CGImageSourceGetCount(reader), expected.count)
            for index in 0..<min(CGImageSourceGetCount(reader), expected.count) {
                let properties = CGImageSourceCopyPropertiesAtIndex(reader, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                XCTAssertEqual(try XCTUnwrap(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double),
                               expected[index], accuracy: 0.009)
            }
            let properties = CGImageSourceCopyProperties(reader, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 3)
        }
    }

    func testVideoCanEncodeHEVCAndOmitAudio() async throws {
        let source = try await videoFixture()
        var options = UpscaleOptions()
        options.export.videoCodec = .hevc
        options.export.videoQuality = .compact
        options.export.keepAudio = false
        let result = try await Upscaler().export(source, to: folder, options: options)
        let asset = AVURLAsset(url: result)
        let video = try await asset.loadTracks(withMediaType: .video)
        let formats = try await XCTUnwrap(video.first).load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_HEVC)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    private func readImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func fixture(transparent: Bool) throws -> CGImage {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 40, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent {
            bitmap.setFillColor(red: 0.15, green: 0.2, blue: 0.3, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
        }
        bitmap.setFillColor(red: 0.1, green: 0.7, blue: 0.8, alpha: 1)
        bitmap.fill(CGRect(x: 8, y: 6, width: 24, height: 12))
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func videoFixture(width: Int = 64, height: Int = 48, frameCount: Int = 8) async throws -> URL {
        let picture = folder.appendingPathComponent("Picture.mov")
        let writer = try AVAssetWriter(outputURL: picture, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(video)
        guard writer.startWriting() else { throw writer.error ?? UpscaleError.encode }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        let context = CIContext()
        for index in 0..<frameCount {
            for _ in 0..<500 where !video.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel)
            let buffer = try XCTUnwrap(pixel)
            context.render(CIImage(color: CIColor(red: Double(index) / Double(frameCount), green: 0.7, blue: 0.8))
                .cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(frameCount))))
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? UpscaleError.encode }

        let sound = folder.appendingPathComponent("Tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        pcm.frameLength = pcm.frameCapacity
        let channel = try XCTUnwrap(pcm.floatChannelData)[0]
        for frame in 0..<Int(pcm.frameLength) { channel[frame] = 0.1 * sin(Float(frame) * 0.06269) }
        do {
            let file = try AVAudioFile(forWriting: sound, settings: format.settings)
            try file.write(from: pcm)
        }

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        for (url, type) in [(picture, AVMediaType.video), (sound, .audio)] {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let part = try XCTUnwrap(composition.addMutableTrack(withMediaType: type,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid))
            try part.insertTimeRange(range, of: track, at: .zero)
            if type == .video { part.preferredTransform = rotation }
        }
        let mux = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let source = folder.appendingPathComponent("Portrait.mov")
        try await mux.export(to: source, as: .mov)
        return source
    }
}
