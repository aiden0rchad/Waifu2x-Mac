import Foundation

public struct WorkspaceSettings: Codable, Equatable, Sendable {
    public var options = UpscaleOptions(preset: Preset.available.contains(.realCUGAN) ? .realCUGAN : .illustration)
    public var besideOriginals = true
    public var folderPath: String?
    public var keepAwake = true
    public var revealWhenDone = false

    public init() {}

    public static func restore(from data: Data?) -> Self {
        guard let data, var settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if let path = settings.folderPath {
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &directory) || !directory.boolValue {
                settings.folderPath = nil
            }
        }
        return settings
    }
}
