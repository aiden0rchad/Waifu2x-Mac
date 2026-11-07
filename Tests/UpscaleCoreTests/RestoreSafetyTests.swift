import CoreImage
import XCTest
@testable import UpscaleCore

final class RestoreSafetyTests: XCTestCase {
    func testPromptDetailsReferencesAndCap() throws {
        let url = URL(fileURLWithPath: "/fixture")
        for references in [[], [url]] {
            for details in ["", "  purple eyes with orange gradient \n", String(repeating: "👩🏽‍🎨", count: 205)] {
                var settings = RestoreSettings()
                settings.characterDetails = details
                let arguments = try MfluxCommand.arguments(model: url, input: url, references: references,
                    output: url, size: .init(width: 128, height: 128), settings: settings)
                let trimmed = String(details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                let expected = settings.prompt + (trimmed.isEmpty ? "" : " Character details: \(trimmed).")
                    + (references.isEmpty ? "" : " " + MfluxCommand.referencePrompt)
                XCTAssertEqual(arguments[try XCTUnwrap(arguments.firstIndex(of: "--prompt")) + 1], expected)
            }
        }
    }

    func testOldSettingsDefaultsAndRoundTrip() throws {
        var settings = try JSONDecoder().decode(RestoreSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.characterDetails, "")
        XCTAssertTrue(settings.safetyCheck)
        settings.characterDetails = "purple eyes"
        settings.safetyCheck = false
        XCTAssertEqual(try JSONDecoder().decode(RestoreSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.characterDetails = "  " + String(repeating: "x", count: 205) + "\n"
        let capped = try JSONDecoder().decode(RestoreSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(capped.characterDetails, String(repeating: "x", count: 200))
    }

    func testChangedFractionIdenticalBlobAndShiftedLineArt() throws {
        try requireRestoreRendering()
        let white = Self.white(390)
        XCTAssertEqual(try RestoreSafety.changedFraction(base: white, result: white), 0)
        let blob = Self.black(CGRect(x: 130, y: 130, width: 117, height: 117)).composited(over: white)
        XCTAssertEqual(try RestoreSafety.changedFraction(base: white, result: blob), 0.09, accuracy: 0.02)
        let line = Self.black(CGRect(x: 130, y: 30, width: 3, height: 330))
        let shifted = line.transformed(by: CGAffineTransform(translationX: 1, y: 0))
        XCTAssertLessThan(try RestoreSafety.changedFraction(base: line.composited(over: white),
            result: shifted.composited(over: white)), RestoreSafety.limit)
        // Downscaling preserves the same decision; smaller images are never enlarged.
        let larger = blob.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        XCTAssertEqual(try RestoreSafety.changedFraction(base: Self.white(780), result: larger), 0.09, accuracy: 0.02)
        XCTAssertEqual(try RestoreSafety.changedFraction(base: Self.white(16), result: Self.white(16)), 0)
    }

    func testCPUMetricIdenticalBlobShiftAndClampedEdges() throws {
        let side = 390
        let white = [Float](repeating: 1, count: side * side)
        var blob = white, lines = white, shifted = white
        for y in 130..<247 { for x in 130..<247 { blob[y * side + x] = 0 } }
        for y in 30..<360 { for x in 130..<133 {
            lines[y * side + x] = 0
            shifted[y * side + x + 1] = 0
        } }
        XCTAssertEqual(try RestoreSafety.changedFraction(base: white, result: white, width: side, height: side), 0)
        XCTAssertEqual(try RestoreSafety.changedFraction(base: white, result: blob, width: side, height: side), 0.09, accuracy: 0.02)
        XCTAssertLessThan(try RestoreSafety.changedFraction(base: lines, result: shifted, width: side, height: side), RestoreSafety.limit)
        for side in [1, 16] {
            let flat = [Float](repeating: 0.7, count: side * side)
            let blurred = try RestoreGuard.blur(flat, width: side, height: side, sigma: 4)
            for value in blurred { XCTAssertEqual(value, 0.7, accuracy: 0.00001) }
        }
        XCTAssertThrowsError(try RestoreSafety.changedFraction(base: [], result: [], width: 0, height: side))
    }

    func testRetriesRemoveReferencesThenChangeSeedAndFallback() async throws {
        try requireRestoreRendering()
        for (bad, references, expected) in [
            ([true, false], true, RestoreOutcome.restoredWithoutReferences),
            ([true, true, true], true, .baseFallback),
            ([true, false], false, .restored),
            ([false], true, .restored)
        ] {
            let (result, calls, progress, base) = try await sequence(bad: bad, references: references)
            XCTAssertEqual(result.outcome, expected)
            XCTAssertEqual(calls.count, bad.count)
            XCTAssertEqual(calls[0].contains("/reference.png"), references)
            for call in calls.dropFirst() { XCTAssertFalse(call.contains("/reference.png")) }
            let seeds = calls.map { $0[$0.firstIndex(of: "--seed")! + 1] }
            XCTAssertEqual(seeds, references ? Array(["7", "7", "8"].prefix(bad.count)) : ["7", "8"])
            for call in calls {
                XCTAssertTrue(call[call.firstIndex(of: "--prompt")! + 1].contains("Character details: purple eyes."))
            }
            XCTAssertEqual(progress, progress.sorted())
            if expected == .baseFallback {
                let renderer = FrameRenderer()
                XCTAssertEqual(try Upscaler.gifFrameHash(renderer.image(result.image)),
                    try Upscaler.gifFrameHash(renderer.image(base)))
            }
        }
    }

    func testSafetyOffRunsOnceAndStrengthDoesNotHideUnsafeResult() async throws {
        try requireRestoreRendering()
        let disabled = try await sequence(bad: [true], references: true, safety: false)
        XCTAssertEqual(disabled.0.outcome, .restored)
        XCTAssertEqual(disabled.1.count, 1)
        let zeroStrength = try await sequence(bad: [true, true], references: false, strength: 0)
        XCTAssertEqual(zeroStrength.0.outcome, .baseFallback)
        XCTAssertEqual(zeroStrength.1.count, 2)
    }

    func testCancellationDuringRetryStopsSequence() async throws {
        try requireRestoreRendering()
        do {
            _ = try await sequence(bad: [true, true, false], references: true, cancelAt: 2)
            XCTFail("Retry must propagate cancellation")
        } catch is CancellationError {}
    }

    func testSummaryCountsAndNotes() {
        var summary = RestoreSummary()
        XCTAssertNil(summary.note(for: .image))
        summary.record(.restored)
        summary.record(.restoredWithoutReferences)
        summary.record(.restoredWithoutReferences)
        XCTAssertEqual(summary.note(for: .image), "AI: without references")
        summary.record(.baseFallback)
        XCTAssertEqual(summary.note(for: .gif), "AI: 2 frames without references, 1 frame base only")
        XCTAssertEqual(summary.note(for: .image), "AI: base upscale only (safety check)")
        XCTAssertEqual(summary.restored, 1)
    }

    private func sequence(bad: [Bool], references: Bool, safety: Bool = true, strength: Double = 1,
                          cancelAt: Int? = nil) async throws -> (RestoreResult, [[String]], [Double], CIImage) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer = FrameRenderer()
        let base = Self.white(128)
        let blob = Self.black(CGRect(x: 40, y: 40, width: 40, height: 40)).composited(over: base)
        let badURL = folder.appendingPathComponent("bad.png")
        try renderer.context.writePNGRepresentation(of: blob, to: badURL, format: .RGBA8, colorSpace: renderer.colorSpace)
        let runner = SafetyRunner(bad: bad, fixture: badURL, cancelAt: cancelAt)
        let pipeline = DiffusionRestore(executable: folder, model: folder) { _, arguments, output in
            try await runner.run(arguments, output: output)
        }
        var settings = RestoreSettings()
        settings.characterDetails = "purple eyes"
        settings.keepOriginalColours = false
        settings.safetyCheck = safety
        settings.strength = strength
        let progress = SafetyProgress()
        let result = try await pipeline.restoreIntermediate(base,
            references: references ? [URL(fileURLWithPath: "/reference.png")] : [], executable: folder, model: folder,
            directory: folder, settings: settings, renderer: renderer) { progress.append($0) }
        // Materialize before the temporary attempt files disappear.
        let image = CIImage(cgImage: try renderer.image(result.image))
        return (RestoreResult(image: image, outcome: result.outcome), await runner.calls, progress.values, base)
    }

    private static func white(_ side: Int) -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private static func black(_ rect: CGRect) -> CIImage { CIImage(color: .black).cropped(to: rect) }
}

private actor SafetyRunner {
    let bad: [Bool]
    let fixture: URL
    let cancelAt: Int?
    var calls: [[String]] = []
    init(bad: [Bool], fixture: URL, cancelAt: Int?) {
        self.bad = bad; self.fixture = fixture; self.cancelAt = cancelAt
    }
    func run(_ arguments: [String], output: @Sendable (String) -> Void) throws {
        calls.append(arguments)
        if calls.count == cancelAt { throw CancellationError() }
        guard calls.count <= bad.count else { throw UpscaleError.render }
        let input = URL(fileURLWithPath: arguments[try XCTUnwrap(arguments.firstIndex(of: "--image-paths")) + 1])
        let destination = URL(fileURLWithPath: arguments[try XCTUnwrap(arguments.firstIndex(of: "--output")) + 1])
        try FileManager.default.copyItem(at: bad[calls.count - 1] ? fixture : input, to: destination)
        output("0/4 [start]\r4/4 [done]\n")
    }
}

private final class SafetyProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.withLock { storage } }
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
}
