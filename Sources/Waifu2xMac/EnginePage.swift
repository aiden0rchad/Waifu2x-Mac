import SwiftUI
import UpscaleCore

struct EnginePage: View {
    @Bindable var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: EngineSection = .illustration
    @State private var sectionFrames: [EngineSection: CGRect] = [:]
    @State private var scrollGeometry: ScrollGeometry?
    @State private var followsScroll = false
    private let groups: [(EngineSection, [Preset])] = [
        (.illustration, [.realCUGAN, .realESRGAN, .anime4k, .anime4kRestore, .waifu2xArt, .illustration]),
        (.photo, [.realSR, .realSRJPEG, .waifu2xPhoto, .photo]),
        (.general, [.fast, .enhance])
    ]
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16)]
    private var sections: [EngineSection] { EngineSection.allCases.filter { $0 != .video || workspace.hasVideo } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    PageHeader(title: "Choose an Engine",
                               subtitle: "Compare speed and quality — you can preview the result on the next page.") {
                        PresetsMenu(workspace: workspace)
                    }
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.0 == .illustration ? "Illustration & Anime" : group.0.rawValue)
                                    .font(.title3.weight(.semibold)).id(group.0)
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(group.1, id: \.self) { preset in
                                        EngineCard(workspace: workspace, choice: .preset(preset))
                                            .id(EngineChoice.preset(preset).id)
                                    }
                                }
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("engineContent")) } action: {
                                sectionFrames[group.0] = $0
                                updateSection()
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AI Restore").font(.title3.weight(.semibold)).id(EngineSection.ai)
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(OptionalEngine.all) { engine in
                                    EngineCard(workspace: workspace, choice: .optional(engine))
                                        .id(EngineChoice.optional(engine).id)
                                }
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("engineContent")) } action: {
                            sectionFrames[.ai] = $0
                            updateSection()
                        }
                        if workspace.hasVideo {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Video").font(.title3.weight(.semibold)).id(EngineSection.video)
                                Text("Used for video files; GIFs and images use the engine above.")
                                    .font(.callout).foregroundStyle(.secondary)
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(VideoEngine.allCases, id: \.self) { engine in
                                        EngineCard(workspace: workspace, choice: .video(engine))
                                            .id(EngineChoice.video(engine).id)
                                    }
                                }
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("engineContent")) } action: {
                                sectionFrames[.video] = $0
                                updateSection()
                            }
                        }
                    }
                }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                    .frame(maxWidth: 1100).frame(maxWidth: .infinity).coordinateSpace(name: "engineContent")
            }
            .softTopScrollBar {
                sectionPicker(proxy: proxy).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .softTopScrollEdge()
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                scrollGeometry = geometry
                updateSection()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking {
                    followsScroll = true
                    updateSection()
                }
            }
            .onAppear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    followsScroll = false
                    section = selectedSection
                    if let choice = initialScrollChoice { proxy.scrollTo(choice.id, anchor: .center) }
                }
            }
        }
        .background { Color.black.opacity(0.25).ignoresSafeArea() }
        .disabled(workspace.isExporting)
    }

    private func sectionPicker(proxy: ScrollViewProxy) -> some View {
        Picker("Jump to Section", selection: Binding(get: { section }, set: { target in
            followsScroll = false
            section = target
            withAnimation(reduceMotion ? nil : .smooth) {
                proxy.scrollTo(target, anchor: .top)
            }
        })) {
            ForEach(sections, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel("Jump to Section")
    }

    private func updateSection() {
        guard followsScroll, let geometry = scrollGeometry else { return }
        if geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 8 {
            section = sections.last ?? .illustration
        } else if let visible = sections.first(where: {
            (sectionFrames[$0]?.maxY ?? -.infinity) > geometry.visibleRect.minY + geometry.contentInsets.top
        }) {
            section = visible
        }
    }

    private var selectedSection: EngineSection {
        if workspace.usesOnlyVideoModel { return .video }
        if workspace.options.usesAI { return .ai }
        return groups.first { $0.1.contains(workspace.options.preset) }?.0 ?? .illustration
    }

    private var initialScrollChoice: EngineChoice? {
        if workspace.usesOnlyVideoModel { return .video(workspace.options.videoEngine) }
        if let engine = OptionalEngine.all.first(where: { $0.id == workspace.options.optionalEngineID }) {
            return .optional(engine)
        }
        return groups[0].1.contains(workspace.options.preset) ? nil : .preset(workspace.options.preset)
    }
}

private enum EngineSection: String, CaseIterable {
    case illustration = "Illustration", photo = "Photo", general = "General", ai = "AI", video = "Video"
}

@MainActor private enum EngineChoice {
    case preset(Preset), optional(OptionalEngine), video(VideoEngine)

    var id: String {
        switch self {
        case let .preset(preset): "preset-" + preset.rawValue
        case let .optional(engine): "optional-" + engine.id
        case let .video(engine): "video-" + engine.rawValue
        }
    }

    var name: String {
        switch self {
        case let .preset(preset): preset.rawValue
        case let .optional(engine): engine.name
        case let .video(engine): engine.rawValue
        }
    }
    var appearance: EngineAppearance {
        switch self {
        case let .preset(preset): preset.appearance
        case .optional: .restore
        case let .video(engine): engine.appearance
        }
    }
    var recommended: Bool {
        if case let .preset(preset) = self { return preset == .realCUGAN || preset == .realSR }
        return false
    }
    var tagline: String {
        switch self {
        case let .preset(preset): preset.tagline
        case let .optional(engine): engine.tagline
        case let .video(engine): engine.tagline
        }
    }
    var detail: String {
        switch self {
        case let .preset(preset): preset.detail
        case let .optional(engine): engine.detail
        case let .video(engine): engine.detail + " " + engine.inputNote
        }
    }
    var profile: EngineProfile {
        switch self {
        case let .preset(preset): preset.engineProfile
        case let .optional(engine): EngineProfile(engine.speed, engine.quality, "about 25 s per image", "Fine restoration")
        case let .video(engine): engine.engineProfile
        }
    }
    var available: Bool {
        if case let .preset(preset) = self { return Preset.available.contains(preset) }
        return true
    }

    func isSelected(in workspace: Workspace) -> Bool {
        switch self {
        case let .preset(preset): workspace.options.optionalEngineID == nil && workspace.options.preset == preset
        case let .optional(engine): workspace.options.optionalEngineID == engine.id
        case let .video(engine): workspace.options.videoEngine == engine
        }
    }

    func select(in workspace: Workspace) {
        switch self {
        case let .preset(preset):
            let videoOnly = workspace.usesOnlyVideoModel
            workspace.options.preset = preset
            workspace.options.optionalEngineID = nil
            if videoOnly { workspace.options.videoEngine = .spatial }
        case let .optional(engine): workspace.options.optionalEngineID = engine.id
        case let .video(engine): workspace.options.videoEngine = engine
        }
    }
}

private struct EngineCard: View {
    let workspace: Workspace
    let choice: EngineChoice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var selected: Bool { choice.isSelected(in: workspace) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { choice.select(in: workspace) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        EngineSymbolTile(symbol: choice.appearance.symbol)
                            .tinted(choice.appearance.tint, endTint: choice.appearance.endTint)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(choice.name).font(.headline).lineLimit(1)
                                if choice.recommended {
                                    Text("Recommended").font(.caption2.weight(.semibold)).fixedSize()
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(Color(nsColor: .controlAccentColor).opacity(0.18), in: Capsule())
                                }
                            }
                            Text(choice.tagline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .controlAccentColor))
                        }
                    }
                    Text(choice.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        EngineRating(title: "Speed", value: choice.profile.speed, word: choice.profile.speedLabel)
                        EngineRating(title: "Quality", value: choice.profile.quality, word: choice.profile.qualityLabel)
                    }
                    if !choice.available {
                        Text("Not available on this Mac").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!choice.available)
            .accessibilityElement(children: .combine).accessibilityLabel(choice.name).accessibilityHint(choice.tagline)
            .accessibilityValue((choice.recommended ? "Recommended. " : "") + "\(choice.detail) Speed \(choice.profile.speed) out of 5, \(choice.profile.speedLabel). Quality \(choice.profile.quality) out of 5, \(choice.profile.qualityLabel).")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if case let .optional(engine) = choice {
                VStack(alignment: .leading, spacing: 12) {
                    if workspace.engineLibrary.checking {
                        Text(OptionalEngineLibrary.size(engine.downloadBytes)).font(.caption).foregroundStyle(.secondary)
                    } else if workspace.engineLibrary[engine].installed {
                        Label {
                            Text("Installed · 4-bit · \(OptionalEngineLibrary.size(engine.downloadBytes))")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }.font(.caption)
                    } else {
                        Text("\(OptionalEngineLibrary.size(engine.downloadBytes)) download · needs \(engine.requiredRAMGB) GB memory")
                            .font(.caption).foregroundStyle(.secondary)
                        OptionalEngineControls(workspace: workspace, engine: engine, compact: true)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .shadow(color: selected ? Color(nsColor: .controlAccentColor).opacity(0.35) : .clear, radius: 12)
        .opacity(choice.available ? 1 : 0.45)
        .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .spring, value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct EngineRating: View {
    let title: String
    let value: Int
    let word: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 52, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { index in
                    Circle().fill(index <= value ? AnyShapeStyle(Color(nsColor: .controlAccentColor)) : AnyShapeStyle(.quaternary))
                        .frame(width: 8, height: 8)
                }
            }
            Text(word).fixedSize(horizontal: false, vertical: true)
        }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue("\(value) out of 5, \(word)")
    }
}

struct EngineAppearance {
    let symbol: String
    let tint: Color
    var endTint: Color?

    init(_ symbol: String, fallback: String, tint: Color, endTint: Color? = nil) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? fallback : symbol
        self.tint = tint
        self.endTint = endTint
    }

    static let restore = EngineAppearance("sparkles", fallback: "wand.and.stars", tint: .purple, endTint: .indigo)
}

extension Preset {
    var appearance: EngineAppearance {
        switch self {
        case .realCUGAN: EngineAppearance("pencil.and.outline", fallback: "pencil", tint: .pink)
        case .realESRGAN: EngineAppearance("sparkles.tv", fallback: "tv", tint: .pink)
        case .anime4k: EngineAppearance("bolt.fill", fallback: "bolt.fill", tint: .pink)
        case .anime4kRestore: EngineAppearance("pencil.tip.crop.circle.badge.plus", fallback: "pencil.tip", tint: .pink)
        case .waifu2xArt: EngineAppearance("paintpalette.fill", fallback: "paintbrush.fill", tint: .pink)
        case .illustration: EngineAppearance("scribble.variable", fallback: "scribble", tint: .pink)
        case .realSR: EngineAppearance("camera.aperture", fallback: "camera", tint: .orange)
        case .realSRJPEG: EngineAppearance("photo.badge.checkmark", fallback: "photo", tint: .orange)
        case .waifu2xPhoto: EngineAppearance("camera.fill", fallback: "camera", tint: .orange)
        case .photo: EngineAppearance("camera.filters", fallback: "camera", tint: .orange)
        case .fast: EngineAppearance("hare.fill", fallback: "hare", tint: .teal)
        case .enhance: EngineAppearance("apple.intelligence", fallback: "wand.and.stars", tint: .teal)
        }
    }
}

extension VideoEngine {
    var appearance: EngineAppearance {
        switch self {
        case .spatial: EngineAppearance("film", fallback: "film", tint: .red)
        case .safmn: EngineAppearance("film.stack", fallback: "film", tint: .red)
        case .nano: EngineAppearance("waveform.path.ecg.rectangle", fallback: "waveform.path.ecg", tint: .red)
        case .nanoDetail: EngineAppearance("sparkle.magnifyingglass", fallback: "magnifyingglass", tint: .red)
        }
    }
}

extension EngineSymbolTile {
    func tinted(_ tint: Color = Color(nsColor: .controlAccentColor), endTint: Color? = nil) -> some View {
        Image(systemName: symbol).font(.system(size: size / 2, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.8), endTint ?? tint], startPoint: .top, endPoint: .bottom))
            }
            .accessibilityHidden(true)
    }
}
