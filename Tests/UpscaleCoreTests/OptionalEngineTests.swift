import XCTest
@testable import UpscaleCore

final class OptionalEngineTests: XCTestCase {
    func testRegistryAndResources() throws {
        let engine = OptionalEngine.fluxKleinRestore
        XCTAssertEqual(try JSONDecoder().decode(OptionalEngine.self, from: JSONEncoder().encode(engine)), engine)
        XCTAssertEqual(engine.supportedMedia, [.image, .gif])
        XCTAssertTrue(engine.repository.hasSuffix("4bit"))
        XCTAssertThrowsError(try engine.checkResources(memory: 8_000_000_000, freeDisk: 100_000_000_000, needsRuntime: true))
        XCTAssertThrowsError(try engine.checkResources(memory: 16_000_000_000, freeDisk: 5_000_000_000, needsRuntime: true))
        XCTAssertNoThrow(try engine.checkResources(memory: 16_000_000_000, freeDisk: 8_000_000_000, needsRuntime: true))
    }

    func testManifestVerification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("weights")
        try Data("abc".utf8).write(to: file)
        let entry = try EngineFile(path: "weights", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let manifest = EngineManifest(id: "test", revision: "pinned", files: [entry])
        try manifest.write(to: folder)
        XCTAssertEqual(try EngineManifest.read(from: folder), manifest)
        XCTAssertEqual(manifest.bytes, 3)
        try manifest.verify(in: folder, id: "test", revision: "pinned")
        try Data("abd".utf8).write(to: file)
        XCTAssertThrowsError(try manifest.verify(in: folder, id: "test", revision: "pinned"))
        XCTAssertThrowsError(try manifest.verify(in: folder, id: "test", revision: "other"))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try manifest.verify(in: folder, id: "test", revision: "pinned"))
    }

    func testManifestCaptureThroughAliasUsesRelativePaths() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual = base.appendingPathComponent("physical!"), alias = base.appendingPathComponent("a")
        let runtime = actual.appendingPathComponent("runtime")
        let linkedRuntime = alias.appendingPathComponent("runtime")
        let fm = FileManager.default
        try fm.createDirectory(at: runtime.appendingPathComponent("uv-aarch64-apple-darwin"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createSymbolicLink(at: alias, withDestinationURL: actual)
        for name in ["uv", "uvx"] {
            try Data("abc".utf8).write(to: runtime.appendingPathComponent("uv-aarch64-apple-darwin/\(name)"))
        }
        try fm.createDirectory(at: runtime.appendingPathComponent("metadata"), withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: runtime.appendingPathComponent("metadata/manifest.json"))
        let expected = ["metadata/manifest.json", "uv-aarch64-apple-darwin/uv", "uv-aarch64-apple-darwin/uvx"]
        let manifest = try EngineManifest.capture(in: linkedRuntime, id: "runtime", revision: "test")
        XCTAssertEqual(manifest.files.map(\.path), expected)
        try manifest.verify(in: linkedRuntime, id: "runtime", revision: "test")
        try manifest.write(to: linkedRuntime)
        XCTAssertEqual(try EngineManifest.capture(in: linkedRuntime, id: "runtime", revision: "test"), manifest,
                       "Exclude only the install manifest, not package files named manifest.json")
    }

    func testUnsafePathsAndFileList() throws {
        for path in ["../escape", "/absolute", "x/../y", "a//b", "manifest.json", "x.partial"] {
            XCTAssertThrowsError(try EngineFile(path: path, size: 1), path)
        }
        let json = #"{"siblings":[{"rfilename":".gitattributes"},{"rfilename":"transformer/weights.safetensors","lfs":{"size":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}},{"rfilename":"tokenizer/config.json","size":2}]}"#
        let files = try HuggingFaceFiles.parse(Data(json.utf8))
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].size, 3)
        XCTAssertNotNil(files[0].sha256)
        XCTAssertThrowsError(try HuggingFaceFiles.parse(Data(#"{"siblings":[{"rfilename":"../escape","size":1}]}"#.utf8)))
    }

    func testIntermediateBudget() throws {
        for size in [Dimensions(width: 40, height: 24), Dimensions(width: 640, height: 784),
                     Dimensions(width: 6000, height: 4000), Dimensions(width: 1, height: 16000),
                     Dimensions(width: 1025, height: 1025)] {
            let result = try RestorePlanner.intermediate(source: size, target: size)
            XCTAssertEqual(result.width % 16, 0)
            XCTAssertEqual(result.height % 16, 0)
            XCTAssertLessThanOrEqual(max(result.width, result.height), 1024)
            XCTAssertLessThanOrEqual(result.width * result.height, 1_050_000)
        }
        XCTAssertThrowsError(try RestorePlanner.intermediate(source: .init(width: 0, height: 1), target: .init(width: 1, height: 1)))
        XCTAssertEqual(try RestorePlanner.intermediate(source: .init(width: 800, height: 608), target: .init(width: 160, height: 120)),
                       Dimensions(width: 800, height: 608), "Restore before shrinking the final output")
    }

    func testResumePlanning() throws {
        XCTAssertEqual(try ResumePlan.response(status: 206, offset: 3, contentRange: "bytes 3-8/9", total: 9), .append)
        XCTAssertEqual(try ResumePlan.response(status: 200, offset: 3, contentRange: nil, total: 9), .restart)
        XCTAssertThrowsError(try ResumePlan.response(status: 206, offset: 3, contentRange: "bytes 0-8/9", total: 9))
        XCTAssertThrowsError(try ResumePlan.response(status: 416, offset: 3, contentRange: nil, total: 9))
    }
}
