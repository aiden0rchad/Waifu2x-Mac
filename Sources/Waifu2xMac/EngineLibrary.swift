import SwiftUI
import UpscaleCore

struct EngineProfile {
    let speed: Int
    let quality: Int
    let speedLabel: String
    let qualityLabel: String

    init(_ speed: Int, _ quality: Int, _ speedLabel: String, _ qualityLabel: String) {
        self.speed = speed
        self.quality = quality
        self.speedLabel = speedLabel
        self.qualityLabel = qualityLabel
    }
}

extension Preset {
    var symbol: String {
        switch self {
        case .fast: "hare.fill"
        case .enhance: "wand.and.stars"
        case .realSR, .realSRJPEG, .waifu2xPhoto, .photo: "camera.fill"
        default: "paintbrush.pointed.fill"
        }
    }

    var engineProfile: EngineProfile {
        switch self {
        case .anime4k: .init(4, 4, "Fast", "Clean outlines")
        case .anime4kRestore: .init(3, 5, "Moderate", "Line restoration")
        case .waifu2xArt: .init(2, 4, "Slower", "Illustration detail")
        case .waifu2xPhoto: .init(2, 4, "Slower", "Photo detail")
        case .realCUGAN: .init(3, 5, "Moderate", "Clean line art")
        case .realESRGAN: .init(4, 4, "Fast", "Crisp textures")
        case .realSR: .init(1, 5, "Slowest", "Photo texture")
        case .realSRJPEG: .init(1, 5, "Slowest", "JPEG cleanup")
        case .illustration: .init(5, 3, "Very fast", "Edge contrast")
        case .photo: .init(5, 3, "Very fast", "Light cleanup")
        case .fast: .init(5, 2, "Very fast", "Quick resize")
        case .enhance: .init(4, 4, "Fast when active", "Native detail")
        }
    }
}

extension Workspace {
    var selectedEngineSymbol: String { usesOnlyVideoModel ? "film" : options.usesAI ? "sparkles" : options.preset.symbol }
    var selectedEngineName: String { usesOnlyVideoModel ? options.videoEngine.rawValue : options.engineName }
    var selectedEngineTagline: String {
        if usesOnlyVideoModel { return options.videoEngine.tagline }
        return OptionalEngine.all.first { $0.id == options.optionalEngineID }?.tagline ?? options.preset.tagline
    }
}

struct EngineSymbolTile: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol).font(.system(size: size / 2, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: .controlAccentColor),
                        in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension VideoEngine {
    var engineProfile: EngineProfile {
        switch self {
        case .spatial: .init(3, 3, "Varies", "Per-frame")
        case .safmn: .init(3, 4, "Moderate", "Per-frame detail")
        case .nano: .init(2, 4, "Slower", "Temporal detail")
        case .nanoDetail: .init(1, 5, "Slowest", "Fine motion detail")
        }
    }
}
