import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UpscaleCore

final class NeuralScalingTests: XCTestCase {
    func testWeightedTilesPreserveColorsAndPartialEdgeCoordinates() throws {
        for kind in NeuralScaler.Kind.allCases {
            for (width, height) in [(321, 390), (73, 517)] {
                try autoreleasepool {
                    let input = try fixture(width: width, height: height)
                    let factor = kind.factor
                    func canvas(_ w: Int, _ h: Int) throws -> CGContext {
                        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: input.colorSpace!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                        context.interpolationQuality = .none
                        return context
                    }
                    let result = try canvas(width * factor, height * factor)
                    result.setBlendMode(.plusLighter)
                    let rows = NeuralScaler.tiles(length: height, tile: kind.tile, factor: factor, alignment: kind.alignment)
                    let columns = NeuralScaler.tiles(length: width, tile: kind.tile, factor: factor, alignment: kind.alignment)
                    for row in rows {
                        for column in columns {
                            let w = column.weights.count, h = row.weights.count
                            // CGImage cropping is top-down; CGContext placement is bottom-up.
                            let piece = try XCTUnwrap(input.cropping(to: CGRect(x: column.origin,
                                y: height - row.origin - h / factor, width: w / factor, height: h / factor)))
                            let tile = try canvas(w, h)
                            tile.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
                            let weighted = try NeuralScaler.weighted(XCTUnwrap(tile.makeImage()), columns: column.weights, rows: row.weights)
                            result.draw(weighted, in: CGRect(x: column.origin * factor, y: row.origin * factor, width: w, height: h))
                        }
                    }
                    let bytes = try XCTUnwrap(result.data).assumingMemoryBound(to: UInt8.self)
                    let original = try XCTUnwrap(input.dataProvider?.data) as Data
                    var maximumError = 0
                    for y in 0..<height {
                        for x in 0..<width {
                            let pixel = (y * factor + factor / 2) * result.bytesPerRow + (x * factor + factor / 2) * 4
                            for channel in 0..<3 {
                                maximumError = max(maximumError, abs(Int(bytes[pixel + channel]) - Int(original[(y * width + x) * 4 + channel])))
                            }
                        }
                    }
                    XCTAssertLessThanOrEqual(maximumError, 3, "\(kind) / \(width)×\(height): upright, registered, normalized blend")
                }
            }
        }
    }

    func testTileWeightsCoverOddEdgesAndPreserveSamplingPhase() {
        for kind in NeuralScaler.Kind.allCases {
            for length in [1, kind.tile - 1, kind.tile, kind.tile + 1, 2 * kind.tile - 1, 321, 390, 517] {
                let tiles = NeuralScaler.tiles(length: length, tile: kind.tile, factor: kind.factor, alignment: kind.alignment)
                var total = [Float](repeating: 0, count: length * kind.factor)
                XCTAssertEqual(tiles.first?.origin, 0)
                for tile in tiles {
                    XCTAssertEqual(tile.origin % kind.alignment, 0)
                    XCTAssertEqual(tile.weights.count, min(kind.tile, length - tile.origin) * kind.factor)
                    for (pixel, weight) in tile.weights.enumerated() {
                        XCTAssertGreaterThan(weight, 0)
                        total[tile.origin * kind.factor + pixel] += weight
                    }
                }
                XCTAssertTrue(total.allSatisfy { abs($0 - 1) < 0.000001 }, "\(kind) / \(length): no gaps or doubled brightness")
            }
        }
    }

    func testNeuralPassPlanUsesNativePassesAndStopsAtInputLimit() throws {
        let source = Dimensions(width: 321, height: 390)
        for kind in NeuralScaler.Kind.allCases {
            for factor in [2, 3, 4, 8] {
                let target = Dimensions(width: source.width * factor, height: source.height * factor)
                let plan = try FrameRenderer.neuralPlan(from: source, to: target, kind: kind)
                let expected = kind.factor == 2 ? (factor == 2 ? 1 : factor == 8 ? 3 : 2) : (factor == 8 ? 2 : 1)
                XCTAssertEqual(plan.count, expected, "\(kind) / \(factor)×")
                XCTAssertEqual(plan.first, kind)
                XCTAssertTrue(plan.dropFirst().allSatisfy { $0 == kind.continuation })
            }
        }
        XCTAssertEqual(try FrameRenderer.neuralPlan(from: source, to: source, kind: .cuganLow), [])
        XCTAssertEqual(try FrameRenderer.neuralPlan(from: Dimensions(width: 40, height: 24),
            to: Dimensions(width: 50, height: 30), kind: .cuganLow), [])
        XCTAssertEqual(try FrameRenderer.neuralPlan(from: source,
            to: Dimensions(width: source.width * 5 / 2, height: source.height * 5 / 2), kind: .cuganLow), [.cuganLow])
        XCTAssertEqual(try FrameRenderer.neuralPlan(from: Dimensions(width: 200, height: 230),
            to: Dimensions(width: 880, height: 1012), kind: .cuganLow), [.cuganLow, .cugan])
        // The first pass fits (16 MP); a second would produce 64 MP.
        XCTAssertEqual(try FrameRenderer.neuralPlan(from: Dimensions(width: 2000, height: 2000),
            to: Dimensions(width: 7000, height: 7000), kind: .cuganHigh), [.cuganHigh])
        XCTAssertThrowsError(try FrameRenderer.neuralPlan(from: Dimensions(width: 4000, height: 4000),
            to: Dimensions(width: 7000, height: 7000), kind: .cuganLow))
        XCTAssertFalse(NeuralScaler.Kind.cugan.accepts(Dimensions(width: Int.max, height: Int.max)))
        XCTAssertFalse(NeuralScaler.Kind.cugan.accepts(Dimensions(width: 0, height: 1)))
    }

    func testEveryNeuralKindKeepsOddImagesUprightAndContinuous() throws {
        try requireNeuralRendering()
        let renderer = FrameRenderer()
        for kind in NeuralScaler.Kind.allCases {
            let scaler = try NeuralScaler(kind: kind)
            for (width, height) in [(321, 390), (73, 517)] {
                try autoreleasepool {
                    let input = try fixture(width: width, height: height)
                    let scaled = try scaler.scale(CIImage(cgImage: input), context: renderer.context, colorSpace: renderer.colorSpace)
                    XCTAssertEqual(scaled.dimensions, Dimensions(width: width * kind.factor, height: height * kind.factor))
                    let small = try renderer.image(renderer.lanczos(scaled, to: CGRect(x: 0, y: 0, width: width, height: height)))
                    let pixels = try XCTUnwrap(small.dataProvider?.data) as Data
                    let original = try XCTUnwrap(input.dataProvider?.data) as Data
                    var error = 0
                    for y in 0..<height {
                        for x in 0..<width {
                            for channel in 0..<3 {
                                error += abs(Int(pixels[y * small.bytesPerRow + x * 4 + channel]) -
                                             Int(original[y * input.bytesPerRow + x * 4 + channel]))
                            }
                        }
                    }
                    XCTAssertLessThan(Double(error) / Double(width * height * 3), 18, "\(kind): retains source registration")
                    func difference(_ index: Int, vertical: Bool) -> Double {
                        var sum = 0
                        let range = vertical ? 0..<width : 72..<height
                        for p in range {
                            let a = vertical ? index * small.bytesPerRow + p * 4 : p * small.bytesPerRow + index * 4
                            let b = a - (vertical ? small.bytesPerRow : 4)
                            for channel in 0..<3 { sum += abs(Int(pixels[a + channel]) - Int(pixels[b + channel])) }
                        }
                        return Double(sum) / Double(range.count * 3)
                    }
                    for vertical in [true, false] {
                        let length = vertical ? height : width
                        // Check old hard cuts and every edge of the overlapping tiles.
                        let tiles = NeuralScaler.tiles(length: length, tile: kind.tile, factor: 1, alignment: kind.alignment)
                        var boundaries = Set(stride(from: kind.tile, to: length, by: kind.tile))
                        for tile in tiles { boundaries.insert(tile.origin); boundaries.insert(tile.origin + tile.weights.count) }
                        for boundary in boundaries {
                            let pixel = vertical ? height - boundary : boundary
                            guard pixel >= 5, pixel < length - 5 else { continue }
                            let neighbors = [-4, -3, -2, -1, 1, 2, 3, 4].map { difference(pixel + $0, vertical: vertical) }
                            let inside = neighbors.reduce(0, +) / Double(neighbors.count)
                            XCTAssertLessThanOrEqual(difference(pixel, vertical: vertical), inside * 1.75 + 1,
                                "\(kind) \(width)×\(height), \(vertical ? "row" : "column") \(pixel): no artificial tile jump")
                        }
                    }
                }
            }
        }
    }

    func testFourTimesCUGANExportAndPreviewsUseTwoPasses() async throws {
        try requireNeuralRendering()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Gradient.png")
        let input = try fixture(width: 95, height: 71)
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, input, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        let options = UpscaleOptions(size: .quadruple, preset: .realCUGAN)
        let renderer = FrameRenderer()
        let target = Dimensions(width: 380, height: 284)
        let scaled = try await renderer.scale(CIImage(cgImage: input), to: target, options: options, opaque: true)
        XCTAssertEqual(renderer.neuralPasses, [.cuganLow, .cugan])
        XCTAssertEqual(scaled.dimensions, target)
        let expected = try rgba(renderer.image(scaled))
        let output = try await Upscaler().export(source, to: folder, options: options)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(exported.width, target.width)
        XCTAssertEqual(exported.height, target.height)
        try assertClose(rgba(renderer.image(CIImage(cgImage: exported))), expected)
        for focus in [nil, CGPoint(x: 0.5, y: 0.5)] as [CGPoint?] {
            let preview = try await Upscaler().preview(source, options: options, focus: focus)
            XCTAssertEqual(preview.output, target)
            try assertClose(rgba(preview.after), expected)
        }
        let doubled = try await renderer.scale(CIImage(cgImage: input), to: Dimensions(width: 190, height: 142),
                                               options: options, opaque: true)
        XCTAssertEqual(renderer.neuralPasses, [.cuganLow])
        XCTAssertEqual(doubled.dimensions, Dimensions(width: 190, height: 142))
        // A reduced preview must honor a pass count capped by the full export's size.
        let capped = try await renderer.scale(CIImage(cgImage: input), to: target, options: options, opaque: true,
                                              neuralPassPlan: [.cuganLow])
        XCTAssertEqual(renderer.neuralPasses, [.cuganLow])
        XCTAssertEqual(capped.dimensions, target)
    }

    func testFractionalCropAtFourPointFourTimesKeepsCUGANAndSmoothGradients() async throws {
        try requireNeuralRendering()
        let renderer = FrameRenderer()
        let full = CIImage(cgImage: try fixture(width: 240, height: 280))
        let crop = full.topLeftCrop(CGRect(x: 17.3, y: 19.8, width: 199.2, height: 229.2))
        XCTAssertEqual(crop.extent, CGRect(x: 0, y: 0, width: 200, height: 230))
        XCTAssertTrue(renderer.isOpaque(crop), "Fractional crop edges must not bypass Core ML")
        let target = Dimensions(width: 880, height: 1012)
        let options = UpscaleOptions(preset: .realCUGAN)
        let scaled = try await renderer.scale(crop, to: target, options: options, opaque: renderer.isOpaque(crop))
        XCTAssertEqual(renderer.neuralPasses, [.cuganLow, .cugan])
        let actual = try rgba(renderer.image(scaled))

        // The same integer crop with a non-zero CI origin must produce the same image.
        let shifted = full.cropped(to: CGRect(x: 17, y: 31, width: 200, height: 230))
        let translated = try await renderer.scale(shifted, to: target, options: options, opaque: true)
        try assertClose(rgba(renderer.image(translated)), actual)

        func equalNeighbours(_ bytes: Data, width: Int, height: Int) -> Double {
            var equal = 0
            for y in 0..<height { for x in 1..<width {
                let i = (y * width + x) * 4
                if (0..<3).allSatisfy({ bytes[i + $0] == bytes[i - 4 + $0] }) { equal += 1 }
            } }
            return Double(equal) / Double((width - 1) * height)
        }
        let nearest = crop.samplingNearest().transformed(by: CGAffineTransform(scaleX: 4.4, y: 4.4))
            .cropped(to: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        let nearestFraction = try equalNeighbours(rgba(renderer.image(nearest)), width: target.width, height: target.height)
        let fraction = equalNeighbours(actual, width: target.width, height: target.height)
        XCTAssertGreaterThan(nearestFraction, 0.74)
        XCTAssertLessThan(fraction, 0.70, "Repeated pixel fraction: \(fraction), nearest: \(nearestFraction)")
        XCTAssertLessThan(fraction, nearestFraction - 0.05)
    }

    private func requireNeuralRendering() throws {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess else {
            throw XCTSkip("IOSurface unavailable in this sandbox; Core ML image rendering cannot run")
        }
    }

    // GPU and Neural Engine runs can differ by a few levels, so compare with a small tolerance.
    private func assertClose(_ actual: Data, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let worst = zip(actual, expected).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        XCTAssertLessThanOrEqual(worst, 6, "max channel difference \(worst)", file: file, line: line)
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (0..<image.height).reduce(into: Data()) { pixels, y in
            pixels.append(data[y * image.bytesPerRow..<y * image.bytesPerRow + image.width * 4])
        }
    }

    private func fixture(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let stripe = 32 * pow(max(0, cos((Double(x) - 0.7 * Double(y)) * .pi / 12)), 6)
                let channels = [40 + 120 * Double(x) / Double(width - 1) + stripe,
                                55 + 130 * Double(y) / Double(height - 1) + stripe,
                                180 - 60 * Double(x) / Double(width - 1) - 40 * Double(y) / Double(height - 1) + stripe]
                for channel in 0..<3 {
                    bytes[(y * width + x) * 4 + channel] = y < 65 ? (x / 8 % 2 == 0 ? 245 : 10)
                        : y >= 180 && y < 300 && x < 70 ? 10 : UInt8(channels[channel].rounded())
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
