import Foundation

public struct EngineDownloadProgress: Sendable {
    public let phase: String
    public let completed: Int64
    public let total: Int64
    public let bytesPerSecond: Double
    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
    public var secondsLeft: Double? { bytesPerSecond > 0 ? Double(max(0, total - completed)) / bytesPerSecond : nil }
}

// Each transfer owns a serial delegate queue. Cancellation only touches the task under the lock.
final class ResumableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var failure: Error?
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private let file: EngineFile
    private let directory: URL
    private let progress: @Sendable (Int64) -> Void
    private var partial: URL { directory.appendingPathComponent(file.path + ".partial") }

    init(file: EngineFile, directory: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.directory = directory.resolvingSymlinksInPath().standardizedFileURL; self.progress = progress
    }

    func run(url: URL, configuration: URLSessionConfiguration) async throws {
        try Task.checkCancellation()
        _ = try file.validated()
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard partial.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw OptionalEngineError.message("Unsafe download destination.")
        }
        if (try? file.verify(in: directory)) != nil { progress(file.size); return }
        received = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if received >= file.size, FileManager.default.fileExists(atPath: partial.path) {
            if received == file.size, (file.sha256 == nil || (try? EngineFile.digest(partial)) == file.sha256) {
                try publish(); progress(file.size); return
            }
            try FileManager.default.removeItem(at: partial); received = 0
        }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
                self.task = task
                if cancelled { task.cancel() }
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            self.task?.cancel()
            self.lock.unlock()
        }
        try Task.checkCancellation()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let plan = try ResumePlan.response(status: http.statusCode, offset: received,
                                              contentRange: http.value(forHTTPHeaderField: "Content-Range"), total: file.size)
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            handle = try FileHandle(forWritingTo: partial)
            if plan == .restart { try handle?.truncate(atOffset: 0); received = 0 }
            else { try handle?.seekToEnd() }
            report()
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard failure == nil else { return }
            guard received + Int64(data.count) <= file.size else { throw OptionalEngineError.message("Download exceeds its expected size.") }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            report()
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            try handle?.close(); handle = nil
            if let failure { throw failure }
            if let error { throw error }
            guard received == file.size else { throw OptionalEngineError.message("Download is incomplete. Resume to try again.") }
            if let hash = file.sha256, try EngineFile.digest(partial) != hash {
                try FileManager.default.removeItem(at: partial)
                throw OptionalEngineError.message("Download checksum failed. Please try again.")
            }
            try publish()
            continuation?.resume()
        } catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    private func publish() throws {
        let destination = directory.appendingPathComponent(file.path)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func report() {
        if received == file.size || Date().timeIntervalSince(lastReport) >= 0.15 {
            lastReport = Date(); progress(received)
        }
    }
}

// Process output is drained off the caller's actor, bounded, and joined before returning.
enum EngineProcess {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    output: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let state = ProcessState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let process = Process(), pipe = Pipe()
                        process.executableURL = executable; process.arguments = arguments
                        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                        process.standardOutput = pipe; process.standardError = pipe
                        try state.start(process)
                        try pipe.fileHandleForWriting.close()
                        var tail = Data()
                        while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                            tail.append(data)
                            if tail.count > 16_384 { tail.removeFirst(tail.count - 16_384) }
                            output(String(decoding: data, as: UTF8.self))
                        }
                        try pipe.fileHandleForReading.close()
                        process.waitUntilExit()
                        if state.isCancelled { throw CancellationError() }
                        guard process.terminationStatus == 0 else {
                            let text = String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
                            throw OptionalEngineError.message("AI process failed (\(process.terminationStatus)). \(text)\nIf memory is low, close other apps and try again.")
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.cancel() }
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning {
            process.terminate()
            // Escalate for a runtime that ignores SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

enum UVRuntimeArchive {
    static let name = "uv-aarch64-apple-darwin.tar.gz"
    static let directory = "uv-aarch64-apple-darwin"
    static let url = URL(string: "https://github.com/astral-sh/uv/releases/download/0.9.8/\(name)")!
    // The archive digest, not the digest of its .sha256 sidecar:
    // https://github.com/astral-sh/uv/releases/expanded_assets/0.9.8
    static let sha256 = "c021ce28988acbbfcb496e68cd9f2f6ba6401cc6d3292a5d25313873f825e002"
}

public actor EngineInstaller {
    public let paths: EnginePaths
    private let configuration: URLSessionConfiguration
    private let uvArchiveSHA256: String
    private var busy = false

    public init(paths: EnginePaths = EnginePaths(), configuration: URLSessionConfiguration = .ephemeral) {
        self.paths = paths; self.configuration = configuration
        uvArchiveSHA256 = UVRuntimeArchive.sha256
    }

    init(paths: EnginePaths, configuration: URLSessionConfiguration,
         uvArchiveSHA256: String) {
        self.paths = paths; self.configuration = configuration; self.uvArchiveSHA256 = uvArchiveSHA256
    }

    public func installed(_ engine: OptionalEngine) -> Bool { (try? paths.verify(engine)) != nil }
    public func hasPartialInstall(_ engine: OptionalEngine) -> Bool {
        FileManager.default.fileExists(atPath: paths.model(engine).path) || FileManager.default.fileExists(atPath: paths.runtime.path)
    }

    public func install(_ engine: OptionalEngine,
                        progress: @escaping @Sendable (EngineDownloadProgress) -> Void = { _ in }) async throws {
        guard !busy else { throw OptionalEngineError.message("An engine download is already running.") }
        guard OptionalEngine.all.contains(engine) else { throw OptionalEngineError.message("Unknown optional engine.") }
        busy = true
        defer { busy = false }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let runtimeNeeded = (try? paths.verifyRuntime()) == nil
        let attributes = try fm.attributesOfFileSystem(forPath: paths.root.path)
        let freeDisk = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        try engine.checkResources(memory: ProcessInfo.processInfo.physicalMemory, freeDisk: freeDisk, needsRuntime: runtimeNeeded)
        if runtimeNeeded {
            progress(.init(phase: "Installing AI runtime · 1.3 GB", completed: 0,
                           total: engine.downloadBytes + OptionalEngine.runtimeBytes, bytesPerSecond: 0))
            try await installRuntime()
        }
        try Task.checkCancellation()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = URL(string: "https://huggingface.co/api/models/\(engine.repository)/revision/\(engine.revision)?blobs=true")!
        let (data, response) = try await session.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let files = try HuggingFaceFiles.parse(data)
        let directory = paths.model(engine)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let runtime = runtimeNeeded ? OptionalEngine.runtimeBytes : 0
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let start = Date(), prior = completed
            let initial = Int64((try? directory.appendingPathComponent(file.path + ".partial").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let transfer = ResumableDownload(file: file, directory: directory) { count in
                let speed = Double(max(0, count - initial)) / max(0.1, Date().timeIntervalSince(start))
                progress(.init(phase: "Downloading model", completed: runtime + prior + count,
                               total: runtime + total, bytesPerSecond: speed))
            }
            let url = URL(string: "https://huggingface.co/\(engine.repository)/resolve/\(engine.revision)/")!
                .appendingPathComponent(file.path)
            try await transfer.run(url: url, configuration: configuration)
            completed += file.size
        }
        try Task.checkCancellation()
        let manifest = EngineManifest(id: engine.id, revision: engine.revision, files: files)
        try manifest.verify(in: directory, id: engine.id, revision: engine.revision)
        try manifest.write(to: directory)
        progress(.init(phase: "Installed", completed: runtime + total, total: runtime + total, bytesPerSecond: 0))
    }

    private func installRuntime() async throws {
        let fm = FileManager.default
        let runtime = paths.runtime
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: UVRuntimeArchive.url)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength > 0 else { throw URLError(.badServerResponse) }
        let archive = try EngineFile(path: UVRuntimeArchive.name, size: response.expectedContentLength, sha256: uvArchiveSHA256)
        try await ResumableDownload(file: archive, directory: runtime, progress: { _ in }).run(url: UVRuntimeArchive.url, configuration: configuration)
        try await EngineProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", runtime.appendingPathComponent(archive.path).path, "-C", runtime.path])
        let tools = ["uv", "uvx"].map { runtime.appendingPathComponent("\(UVRuntimeArchive.directory)/\($0)") }
        guard tools.allSatisfy({ fm.isExecutableFile(atPath: $0.path) }) else {
            throw OptionalEngineError.message("The AI runtime archive is missing its uv or uvx executable.")
        }
        let uv = tools[0]
        let venv = runtime.appendingPathComponent("venv")
        if fm.fileExists(atPath: venv.path) { try fm.removeItem(at: venv) }
        let environment = ["UV_PYTHON_INSTALL_DIR": runtime.appendingPathComponent("python").path,
                           "UV_CACHE_DIR": runtime.appendingPathComponent("cache").path,
                           "UV_PYTHON_PREFERENCE": "only-managed", "UV_NO_PROGRESS": "1"]
        try await EngineProcess.run(uv, ["venv", "--python", "3.12", venv.path], environment: environment)
        try await EngineProcess.run(uv, ["pip", "install", "--python", venv.appendingPathComponent("bin/python").path, "mflux==0.24.0"], environment: environment)
        try Task.checkCancellation()
        for name in ["cache", "uv.tar.gz", archive.path] { try? fm.removeItem(at: runtime.appendingPathComponent(name)) }
        try EngineManifest.capture(in: runtime, id: "runtime", revision: "uv-0.9.8-mflux-0.24.0-python-3.12").write(to: runtime)
        try paths.verifyRuntime()
    }

    public func diskBytes(_ engine: OptionalEngine) -> Int64 { Self.diskBytes(paths.model(engine)) }
    public func removalBytes(_ engine: OptionalEngine) -> Int64 {
        diskBytes(engine) + (otherModels(excluding: engine).isEmpty ? Self.diskBytes(paths.runtime) : 0)
    }

    public func remove(_ engine: OptionalEngine) throws -> Int64 {
        guard !busy else { throw OptionalEngineError.message("Cancel the download before removing an engine.") }
        let bytes = removalBytes(engine)
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.model(engine).path) { try fm.removeItem(at: paths.model(engine)) }
        if otherModels(excluding: engine).isEmpty, fm.fileExists(atPath: paths.runtime.path) { try fm.removeItem(at: paths.runtime) }
        return bytes
    }

    private func otherModels(excluding engine: OptionalEngine) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.root.appendingPathComponent("models"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != engine.id && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func diskBytes(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }
}
