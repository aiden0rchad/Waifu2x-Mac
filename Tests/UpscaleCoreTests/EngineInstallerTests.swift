import Foundation
import XCTest
@testable import UpscaleCore

final class EngineInstallerTests: XCTestCase {
    private var folder: URL!
    private var configuration: URLSessionConfiguration!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        configuration = .ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        EngineStubProtocol.holdOpen = false
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testRangeResumeAndAtomicPublish() async throws {
        try Data("abc".utf8).write(to: folder.appendingPathComponent("weights.partial"))
        EngineStubProtocol.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            return (206, ["Content-Range": "bytes 3-5/6"], Data("def".utf8))
        }
        let file = try EngineFile(path: "weights", size: 6)
        try await ResumableDownload(file: file, directory: folder, progress: { _ in })
            .run(url: URL(string: "https://stub.test/weights")!, configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights")), Data("abcdef".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("weights.partial").path))
    }

    func testIgnoredRangeRestartsWithoutAppending() async throws {
        try Data("abc".utf8).write(to: folder.appendingPathComponent("weights.partial"))
        EngineStubProtocol.respond = { _ in (200, [:], Data("abcdef".utf8)) }
        try await ResumableDownload(file: EngineFile(path: "weights", size: 6), directory: folder, progress: { _ in })
            .run(url: URL(string: "https://stub.test/weights")!, configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights")), Data("abcdef".utf8))
    }

    func testDownloadThroughSymbolicLink() async throws {
        let actual = folder.appendingPathComponent("actual-storage"), alias = folder.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        EngineStubProtocol.respond = { _ in (200, [:], Data("abc".utf8)) }
        try await ResumableDownload(file: EngineFile(path: "weights", size: 3), directory: alias, progress: { _ in })
            .run(url: URL(string: "https://stub.test/weights")!, configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: actual.appendingPathComponent("weights")), Data("abc".utf8))
    }

    func testInvalidRangeAndChecksumNeverPublish() async throws {
        try Data("abc".utf8).write(to: folder.appendingPathComponent("weights.partial"))
        EngineStubProtocol.respond = { _ in (206, ["Content-Range": "bytes 0-5/6"], Data("def".utf8)) }
        do {
            try await ResumableDownload(file: EngineFile(path: "weights", size: 6), directory: folder, progress: { _ in })
                .run(url: URL(string: "https://stub.test/weights")!, configuration: configuration)
            XCTFail("Invalid range must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights.partial")), Data("abc".utf8))
        EngineStubProtocol.respond = { _ in (200, [:], Data("abc".utf8)) }
        do {
            let file = try EngineFile(path: "bad", size: 3, sha256: String(repeating: "0", count: 64))
            try await ResumableDownload(file: file, directory: folder, progress: { _ in })
                .run(url: URL(string: "https://stub.test/bad")!, configuration: configuration)
            XCTFail("Bad checksum must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bad").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bad.partial").path))
    }

    func testTruncatedDownloadRetainsPartialAndCancellation() async throws {
        EngineStubProtocol.respond = { _ in (200, [:], Data("abc".utf8)) }
        do {
            try await ResumableDownload(file: EngineFile(path: "weights", size: 6), directory: folder, progress: { _ in })
                .run(url: URL(string: "https://stub.test/weights")!, configuration: configuration)
            XCTFail("Truncated download must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights.partial")), Data("abc".utf8))
        let task = Task {
            try Task.checkCancellation()
            try await ResumableDownload(file: EngineFile(path: "cancelled", size: 6), directory: folder, progress: { _ in })
                .run(url: URL(string: "https://stub.test/cancelled")!, configuration: configuration)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled").path))
    }

    func testFileListThroughStubbedSession() async throws {
        EngineStubProtocol.respond = { request in
            XCTAssertTrue(request.url!.absoluteString.contains("revision/"))
            return (200, [:], Data(#"{"siblings":[{"rfilename":"transformer/config.json","size":3}]}"#.utf8))
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "https://stub.test/revision/pinned?blobs=true")!)
        XCTAssertEqual(try HuggingFaceFiles.parse(data).first?.path, "transformer/config.json")
    }

    func testActiveRequestCancellationRetainsPartialForResume() async throws {
        try Data("abc".utf8).write(to: folder.appendingPathComponent("weights.partial"))
        let started = expectation(description: "Request started")
        EngineStubProtocol.holdOpen = true
        EngineStubProtocol.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            started.fulfill()
            return (206, ["Content-Range": "bytes 3-5/6"], Data("def".utf8))
        }
        defer { EngineStubProtocol.holdOpen = false }
        let directory = folder!, config = configuration!
        let transfer = ResumableDownload(file: try EngineFile(path: "weights", size: 6), directory: directory, progress: { _ in })
        let task = Task { try await transfer.run(url: URL(string: "https://stub.test/weights")!, configuration: config) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Active transfer must cancel") } catch {}
        EngineStubProtocol.holdOpen = false
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights.partial")), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("weights").path))
        EngineStubProtocol.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            return (206, ["Content-Range": "bytes 3-5/6"], Data("def".utf8))
        }
        try await ResumableDownload(file: EngineFile(path: "weights", size: 6), directory: directory, progress: { _ in })
            .run(url: URL(string: "https://stub.test/weights")!, configuration: config)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights")), Data("abcdef".utf8))
    }

    func testRuntimeAndModelInstallWithStubbedNetworkAndProcesses() async throws {
        try await checkRuntimeInstall(root: folder.appendingPathComponent("Engines"))
    }

    func testRuntimeInstallThroughSymbolicLink() async throws {
        let original = folder!
        let real = original.appendingPathComponent("actual-engine-storage")
        let alias = original.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        try await checkRuntimeInstall(root: alias)
    }

    func testRuntimeChecksumFailureDoesNotRunAnUnverifiedBinary() async throws {
        let archive = try await runtimeFixture()
        stubDownloads(archive: archive.data)
        let paths = EnginePaths(root: folder.appendingPathComponent("Engines"))
        // The production initializer must reject this fixture against the actual official pin.
        let installer = EngineInstaller(paths: paths, configuration: configuration)
        do { try await installer.install(.fluxKleinRestore); XCTFail("Checksum must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtime.appendingPathComponent(UVRuntimeArchive.directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtime.appendingPathComponent("manifest.json").path))
    }

    func testPinnedUVAssetIdentity() {
        XCTAssertEqual(UVRuntimeArchive.url.absoluteString, "https://github.com/astral-sh/uv/releases/download/0.9.8/uv-aarch64-apple-darwin.tar.gz")
        XCTAssertEqual(UVRuntimeArchive.sha256, "c021ce28988acbbfcb496e68cd9f2f6ba6401cc6d3292a5d25313873f825e002")
    }

    func testRuntimeArchiveMustPreserveExecutablePermissions() async throws {
        let archive = try await runtimeFixture(executable: false)
        stubDownloads(archive: archive.data)
        let paths = EnginePaths(root: folder.appendingPathComponent("Engines"))
        let installer = EngineInstaller(paths: paths, configuration: configuration, uvArchiveSHA256: archive.sha256)
        do { try await installer.install(.fluxKleinRestore); XCTFail("Non-executable archive must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("executable"), "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtime.appendingPathComponent("manifest.json").path))
    }

    private func checkRuntimeInstall(root: URL) async throws {
        let archive = try await runtimeFixture()
        stubDownloads(archive: archive.data)
        let paths = EnginePaths(root: root)
        // Only network bytes/their digest are fixtures. Extraction, execution, capture, and verification are production code.
        let installer = EngineInstaller(paths: paths, configuration: configuration, uvArchiveSHA256: archive.sha256)
        try await installer.install(.fluxKleinRestore)
        let installed = await installer.installed(.fluxKleinRestore)
        XCTAssertTrue(installed)
        let runtime = try EngineManifest.read(from: paths.runtime)
        let uvPath = "uv-aarch64-apple-darwin/uv"
        XCTAssertTrue(runtime.files.contains { $0.path == uvPath })
        XCTAssertTrue(runtime.files.contains { $0.path == "uv-aarch64-apple-darwin/uvx" })
        XCTAssertFalse(runtime.files.contains { $0.path.hasPrefix("runtime/") })
        XCTAssertEqual(try Data(contentsOf: paths.runtime.appendingPathComponent(uvPath)), archive.script)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.runtime.appendingPathComponent(uvPath).path))
        XCTAssertEqual(try String(contentsOf: paths.runtime.appendingPathComponent("uv-calls.txt"), encoding: .utf8), "venv\npip\n")
        try runtime.verify(in: paths.runtime, id: "runtime", revision: "uv-0.9.8-mflux-0.24.0-python-3.12")
        try runtime.verify(in: root.appendingPathComponent("runtime"), id: "runtime", revision: "uv-0.9.8-mflux-0.24.0-python-3.12")
        let model = try EngineManifest.read(from: paths.model(.fluxKleinRestore))
        XCTAssertEqual(model.revision, OptionalEngine.fluxKleinRestore.revision)
        XCTAssertEqual(model.files.first?.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("bad".utf8).write(to: paths.model(.fluxKleinRestore).appendingPathComponent("transformer/weights.safetensors"))
        let corrupted = await installer.installed(.fluxKleinRestore)
        XCTAssertFalse(corrupted)
    }

    private func runtimeFixture(executable: Bool = true) async throws -> (data: Data, sha256: String, script: Data) {
        let source = folder.appendingPathComponent("fixture-source")
        let tools = source.appendingPathComponent("uv-aarch64-apple-darwin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let script = Data(#"""
        #!/bin/sh
        set -eu
        test "$UV_PYTHON_PREFERENCE" = only-managed
        printf '%s\n' "$1" >> "${UV_PYTHON_INSTALL_DIR%/*}/uv-calls.txt"
        case "$1" in
            venv)
                test "$2" = --python
                test "$3" = 3.12
                mkdir -p "$4/bin"
                printf '#!/bin/sh\nexit 0\n' > "$4/bin/python"
                chmod 755 "$4/bin/python"
                ;;
            pip)
                test "$2" = install
                test "$3" = --python
                test "$5" = mflux==0.24.0
                test -x "$4"
                printf '#!/bin/sh\nexit 0\n' > "${4%/*}/mflux-generate-flux2-edit"
                chmod 755 "${4%/*}/mflux-generate-flux2-edit"
                ;;
            *) exit 2 ;;
        esac
        """#.utf8)
        for (name, contents) in [("uv", script), ("uvx", Data("#!/bin/sh\nexit 0\n".utf8))] {
            let file = tools.appendingPathComponent(name)
            try contents.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
        let archive = folder.appendingPathComponent("fixture.tar.gz")
        try await EngineProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", source.path, "uv-aarch64-apple-darwin"],
                                    environment: ["COPYFILE_DISABLE": "1"])
        return (try Data(contentsOf: archive), try EngineFile.digest(archive), script)
    }

    private func stubDownloads(archive: Data) {
        EngineStubProtocol.respond = { request in
            if request.url == UVRuntimeArchive.url {
                return (200, ["Content-Length": String(archive.count)], request.httpMethod == "HEAD" ? Data() : archive)
            }
            if request.url!.path.contains("/api/models/") {
                XCTAssertTrue(request.url!.absoluteString.contains(OptionalEngine.fluxKleinRestore.revision))
                return (200, [:], Data(#"{"siblings":[{"rfilename":"transformer/weights.safetensors","lfs":{"size":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}}]}"#.utf8))
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/transformer/weights.safetensors"), "Unexpected request: \(request)")
            return (200, [:], Data("abc".utf8))
        }
    }

    func testRemovalFreesRuntimeOnlyForLastModel() async throws {
        let paths = EnginePaths(root: folder)
        let engine = OptionalEngine.fluxKleinRestore
        for directory in [paths.runtime, paths.model(engine), folder.appendingPathComponent("models/other")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: directory.appendingPathComponent("file"))
        }
        let installer = EngineInstaller(paths: paths, configuration: configuration)
        let first = try await installer.remove(engine)
        XCTAssertEqual(first, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.runtime.path))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("models/other"))
        try Data().write(to: folder.appendingPathComponent("models/.DS_Store"))
        let last = try await installer.remove(engine)
        XCTAssertEqual(last, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.runtime.path))
    }
}

private final class EngineStubProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) -> (Int, [String: String], Data))!
    static var holdOpen = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.respond(request)
        if Self.holdOpen { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
