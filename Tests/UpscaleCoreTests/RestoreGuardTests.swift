import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import UpscaleCore

final class RestoreGuardTests: XCTestCase {
    private let width = 128
    private let white = SIMD4<Float>(1, 1, 1, 1)
    private let black = SIMD4<Float>(0, 0, 0, 1)

    private func bar(colour: SIMD4<Float>, hollow: Bool = false, shift: Int = 0) -> [SIMD4<Float>] {
        var pixels = [SIMD4<Float>](repeating: white, count: width * width)
        for y in 24..<104 { for x in (56 + shift)..<(68 + shift) {
            if !hollow || x < 59 + shift || x >= 65 + shift || y < 27 || y >= 101 {
                pixels[y * width + x] = colour
            }
        } }
        return pixels
    }

    func testIdenticalImagesHaveNoProtection() throws {
        let base = bar(colour: black)
        let weights = try RestoreGuard.weights(base: base, restored: base, width: width, height: width)
        XCTAssertTrue(weights.allSatisfy { $0 == 0 })
    }

    func testHollowBarIsRepairedAndDistantPixelsAreUnchanged() throws {
        let base = bar(colour: black), restored = bar(colour: black, hollow: true)
        let weights = try RestoreGuard.weights(base: base, restored: restored, width: width, height: width)
        for y in 27..<101 { for x in 59..<65 {
            let i = y * width + x
            let output = restored[i] * (1 - weights[i]) + base[i] * weights[i]
            XCTAssertLessThanOrEqual(output.x, 0.1)
        } }
        for y in 0..<width { for x in 0..<width where x <= 36 || x >= 87 || y <= 4 || y >= 123 {
            let i = y * width + x
            XCTAssertEqual(weights[i], 0)
            XCTAssertEqual(restored[i] * (1 - weights[i]) + base[i] * weights[i], restored[i])
        } }
    }

    func testShiftedAndSharpenedBlackBarHasNoProtection() throws {
        let base = bar(colour: SIMD4(0.03, 0.03, 0.03, 1))
        for shift in [-1, 0, 1] {
            let weights = try RestoreGuard.weights(base: base, restored: bar(colour: black, shift: shift),
                                                   width: width, height: width)
            XCTAssertLessThanOrEqual(weights.max() ?? 1, 0.05)
        }
    }

    func testSaturatedDarkRedStrokeIsNotProtected() throws {
        let red = SIMD4<Float>(0.5, 0, 0, 1)
        let weights = try RestoreGuard.weights(base: bar(colour: red), restored: bar(colour: red, hollow: true),
                                               width: width, height: width)
        XCTAssertTrue(weights.allSatisfy { $0 == 0 })
    }

    func testIsolatedTwoPixelSpeckIsNotProtected() throws {
        var base = [SIMD4<Float>](repeating: white, count: width * width)
        for y in 63...64 { for x in 63...64 { base[y * width + x] = black } }
        let weights = try RestoreGuard.weights(base: base,
            restored: [SIMD4<Float>](repeating: white, count: base.count), width: width, height: width)
        XCTAssertTrue(weights.allSatisfy { $0 == 0 })
    }

    func testFiltersClampAtImageEdges() throws {
        let base = [SIMD4<Float>](repeating: black, count: width * width)
        let restored = [SIMD4<Float>](repeating: white, count: base.count)
        let weights = try RestoreGuard.weights(base: base, restored: restored, width: width, height: width)
        XCTAssertTrue(weights.allSatisfy { $0 == 1 })
    }

    func testGuardValidation() throws {
        XCTAssertThrowsError(try RestoreGuard.weights(base: [], restored: [], width: 0, height: 1))
        XCTAssertThrowsError(try RestoreGuard.weights(base: [white], restored: [], width: 1, height: 1))
        XCTAssertThrowsError(try RestoreGuard.weights(base: [], restored: [], width: Int.max, height: 2))
    }

    func testGuardCancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RestoreGuard.weights(base: self.bar(colour: self.black),
                restored: self.bar(colour: self.black), width: self.width, height: self.width)
        }
        do { _ = try await task.value; XCTFail("Guard must cancel") }
        catch is CancellationError {}
    }

    func testReferenceCropClampingSizingAndOrientation() throws {
        let url = URL(fileURLWithPath: "/reference.jpg")
        let reference = ReferenceImage(url: url, crop: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.4))
        XCTAssertEqual(try reference.pixelRect(in: .init(width: 400, height: 200)),
                       CGRect(x: 100, y: 20, width: 200, height: 80))
        XCTAssertEqual(ReferenceImage.preparedSize(CGSize(width: 100, height: 50)), CGSize(width: 512, height: 256))
        XCTAssertEqual(ReferenceImage.preparedSize(CGSize(width: 2000, height: 1000)), CGSize(width: 1024, height: 512))
        XCTAssertEqual(ReferenceImage.preparedSize(CGSize(width: 600, height: 800)), CGSize(width: 600, height: 800))
        let oriented = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
            .oriented(forExifOrientation: 6).normalized
        XCTAssertEqual(oriented.dimensions, Dimensions(width: 40, height: 80))
        let rect = try reference.pixelRect(in: oriented.dimensions)
        XCTAssertEqual(rect, CGRect(x: 10, y: 8, width: 20, height: 32))
        XCTAssertEqual(oriented.topLeftCrop(rect).extent, CGRect(x: 0, y: 0, width: 20, height: 32))
        XCTAssertEqual(try ReferenceImage(url: url, crop: CGRect(x: -0.5, y: 0, width: 1, height: 1))
            .pixelRect(in: .init(width: 100, height: 100)), CGRect(x: 0, y: 0, width: 50, height: 100))
        XCTAssertThrowsError(try ReferenceImage(url: url, crop: .zero).pixelRect(in: .init(width: 100, height: 100)))
        XCTAssertEqual(Set([reference, reference]).count, 1)
        XCTAssertNotEqual(reference, ReferenceImage(url: url))
    }

    func testLegacyRestoreSettingsDecodeAndRoundTrip() throws {
        let old = Data(#"{"prompt":"old prompt","seed":42,"keepOriginalColours":false,"strength":0.6,"protection":0.9,"facePrompt":"eyes"}"#.utf8)
        var settings = try JSONDecoder().decode(RestoreSettings.self, from: old)
        XCTAssertTrue(settings.protectStructure)
        XCTAssertEqual(settings.prompt, "old prompt")
        XCTAssertEqual(settings.seed, 42)
        XCTAssertFalse(settings.keepOriginalColours)
        XCTAssertEqual(settings.strength, 0.6)
        settings.protectStructure = false
        let encoded = try JSONEncoder().encode(settings)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(keys["protection"])
        XCTAssertNil(keys["facePrompt"])
        XCTAssertEqual(try JSONDecoder().decode(RestoreSettings.self, from: encoded), settings)
        XCTAssertEqual(try JSONDecoder().decode(RestoreSettings.self, from: Data("{}".utf8)), RestoreSettings())
    }

    func testFractionalCropNormalizesToWholePixels() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 37, y: -19, width: 240, height: 280))
        let crop = image.topLeftCrop(CGRect(x: 17.3, y: 19.8, width: 199.2, height: 229.2))
        XCTAssertEqual(crop.extent, CGRect(x: 0, y: 0, width: 200, height: 230))
        XCTAssertEqual(image.topLeftCrop(CGRect(x: -0.3, y: -0.2, width: 10, height: 10)).extent,
                       CGRect(x: 0, y: 0, width: 10, height: 10))
    }
}


// Core Image's Metal path needs IOSurface even when inference itself is stubbed.
func requireRestoreRendering() throws {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess else {
        throw XCTSkip("IOSurface unavailable in this sandbox; AI Restore rendering cannot run")
    }
}
