import CryptoKit
import Foundation

public struct OptionalEngine: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let tagline: String
    public let licence: String
    public let licenceURL: URL
    public let downloadBytes: Int64
    public let requiredRAMGB: Int
    public let speed: Int
    public let quality: Int
    public let supportedMedia: [MediaKind]
    public let runtime: String
    public let repository: String
    public let revision: String

    private enum CodingKeys: String, CodingKey {
        case id, name, detail, tagline, licence, licenceURL, downloadBytes, requiredRAMGB, speed, quality, supportedMedia, runtime, repository, revision
    }

    public static let fluxKleinRestore = Self(
        id: "flux-klein-restore", name: "FLUX.2 klein Restore",
        detail: "AI Restore · sharper fine detail; may invent small details. Images and GIFs.",
        tagline: "Generative restore for the finest detail",
        licence: "FLUX.2 klein 4B is Apache-2.0 (Black Forest Labs); 4-bit conversion by a community uploader",
        licenceURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B/blob/main/LICENSE.md")!,
        downloadBytes: 4_600_000_000, requiredRAMGB: 16, speed: 1, quality: 5,
        supportedMedia: [.image, .gif], runtime: "mflux==0.24.0 · Python 3.12",
        repository: "Norton0924/FLUX.2-klein-4B-4bit",
        revision: "7da9a04a7dd7312d9a8bc5848d155c74963815ee")
    public static let all = [fluxKleinRestore]
    public static let runtimeBytes: Int64 = 1_300_000_000

    public func checkResources(memory: UInt64, freeDisk: Int64, needsRuntime: Bool) throws {
        guard memory >= UInt64(requiredRAMGB) * 1_000_000_000 else {
            throw OptionalEngineError.message("This engine needs at least \(requiredRAMGB) GB of memory.")
        }
        let needed = downloadBytes + (needsRuntime ? Self.runtimeBytes : 0) + 2_000_000_000
        guard freeDisk >= needed else {
            throw OptionalEngineError.message("Free at least \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) to download this engine.")
        }
    }
}

extension OptionalEngine {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            detail: try values.decode(String.self, forKey: .detail),
            tagline: try values.decodeIfPresent(String.self, forKey: .tagline) ?? Self.fluxKleinRestore.tagline,
            licence: try values.decode(String.self, forKey: .licence),
            licenceURL: try values.decode(URL.self, forKey: .licenceURL),
            downloadBytes: try values.decode(Int64.self, forKey: .downloadBytes),
            requiredRAMGB: try values.decode(Int.self, forKey: .requiredRAMGB),
            speed: try values.decode(Int.self, forKey: .speed),
            quality: try values.decode(Int.self, forKey: .quality),
            supportedMedia: try values.decode([MediaKind].self, forKey: .supportedMedia),
            runtime: try values.decode(String.self, forKey: .runtime),
            repository: try values.decode(String.self, forKey: .repository),
            revision: try values.decode(String.self, forKey: .revision))
    }
}

public enum OptionalEngineError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

public struct EngineFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path != "manifest.json", !path.hasSuffix(".partial"), size >= 0, size <= 1_000_000_000_000,
              sha256 == nil || (sha256!.count == 64 && sha256!.allSatisfy({ $0.isHexDigit })) else {
            throw OptionalEngineError.message("Invalid engine file metadata.")
        }
        self.path = path; self.size = size; self.sha256 = sha256?.lowercased()
    }

    func validated() throws -> Self { try Self(path: path, size: size, sha256: sha256) }

    func verify(in directory: URL, hash: Bool = true) throws {
        _ = try validated()
        let url = directory.appendingPathComponent(path)
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? -1) == size else {
            throw OptionalEngineError.message("Engine file is missing or incomplete: \(path). Download in Engines.")
        }
        if hash, let sha256, try Self.digest(url) != sha256 {
            throw OptionalEngineError.message("Checksum failed: \(path). Download in Engines.")
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct EngineManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let revision: String
    public let files: [EngineFile]
    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public init(id: String, revision: String, files: [EngineFile]) {
        version = 1; self.id = id; self.revision = revision; self.files = files
    }

    public func verify(in directory: URL, id: String, revision: String, hash: Bool = true) throws {
        guard version == 1, self.id == id, self.revision == revision, !files.isEmpty,
              Set(files.map(\.path)).count == files.count else {
            throw OptionalEngineError.message("Engine install is incomplete. Download in Engines.")
        }
        for file in files { try file.verify(in: directory, hash: hash) }
    }

    public func write(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    public static func read(from directory: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    static func capture(in directory: URL, id: String, revision: String) throws -> Self {
        // Enumeration can canonicalize /var to /private/var. Use the same root for both paths.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        var files: [EngineFile] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else { throw OptionalEngineError.message("Unsafe engine file path.") }
            let path = components.dropFirst(rootComponents.count).joined(separator: "/")
            if path == "manifest.json" { continue }
            files.append(try EngineFile(path: path, size: Int64(values.fileSize ?? 0), sha256: EngineFile.digest(url)))
        }
        if let enumerationError { throw enumerationError }
        let manifest = Self(id: id, revision: revision, files: files.sorted { $0.path < $1.path })
        try manifest.verify(in: root, id: id, revision: revision)
        return manifest
    }
}

public struct EnginePaths: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Waifu2x-Mac/Engines", isDirectory: true)) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }
    public var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    public var executable: URL { runtime.appendingPathComponent("venv/bin/mflux-generate-flux2-edit") }
    public func model(_ engine: OptionalEngine) -> URL { root.appendingPathComponent("models/\(engine.id)", isDirectory: true) }

    public func verify(_ engine: OptionalEngine, hash: Bool = true) throws {
        try EngineManifest.read(from: model(engine)).verify(in: model(engine), id: engine.id, revision: engine.revision, hash: hash)
        try verifyRuntime(hash: hash)
    }

    public func verifyRuntime(hash: Bool = true) throws {
        try EngineManifest.read(from: runtime).verify(in: runtime, id: "runtime", revision: "uv-0.9.8-mflux-0.24.0-python-3.12", hash: hash)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("venv/bin/python").path),
              runtime.appendingPathComponent("venv/bin/python").resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/") else {
            throw OptionalEngineError.message("AI runtime is missing. Download in Engines.")
        }
    }
}

public enum RestorePlanner {
    public static func intermediate(source: Dimensions, target: Dimensions) throws -> Dimensions {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { throw UpscaleError.invalidSize }
        let desired = max(source.width, source.height) > max(target.width, target.height) ? source : target
        let width = Double(desired.width), height = Double(desired.height)
        let scale = min(1, 1024 / max(width, height), sqrt(1_050_000 / (width * height)))
        return Dimensions(width: max(16, Int(width * scale) / 16 * 16),
                          height: max(16, Int(height * scale) / 16 * 16))
    }
}

public enum HuggingFaceFiles {
    private struct Response: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let size: Int64; let sha256: String }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        let siblings: [Sibling]
    }

    public static func parse(_ data: Data) throws -> [EngineFile] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let files = try response.siblings.filter { $0.rfilename != ".gitattributes" }.map { item in
            guard let size = item.lfs?.size ?? item.size else { throw OptionalEngineError.message("Missing model file size.") }
            return try EngineFile(path: item.rfilename, size: size, sha256: item.lfs?.sha256)
        }
        guard !files.isEmpty, files.count <= 10_000, Set(files.map(\.path)).count == files.count else {
            throw OptionalEngineError.message("Invalid model file list.")
        }
        return files
    }
}

public enum ResumePlan: Equatable, Sendable {
    case append, restart
    public static func response(status: Int, offset: Int64, contentRange: String?, total: Int64) throws -> Self {
        if status == 200 { return .restart }
        if status == 206, offset > 0, let contentRange,
           contentRange == "bytes \(offset)-\(total - 1)/\(total)" { return .append }
        throw OptionalEngineError.message("The server returned an invalid download response (\(status)).")
    }
}
